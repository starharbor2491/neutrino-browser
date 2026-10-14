// SPDX-License-Identifier: MPL-2.0
import AppKit
import CryptoKit
import Foundation
@preconcurrency import Network
import NeutrinoCore
import Security
import SwiftUI

private struct ChatGPTCredentials: Codable, Sendable {
  var clientID: String
  var subject: String
  var email: String?
  var accessToken: String
  var refreshToken: String?
  var idToken: String
  var scopes: [String]
  var expiresAt: Date
}

/// Official OSS dynamic-agent registration, using Neutrino's own identity.
/// Protocol implementation is separate from the native/account acceptance gate.
@MainActor final class ChatGPTAccount: ObservableObject {
  static let shared = ChatGPTAccount()
  @Published private(set) var connected = false
  @Published private(set) var hasSession = false
  @Published private(set) var busy = false
  @Published private(set) var email: String?
  @Published private(set) var models: [String] = []
  @Published private(set) var status: String?
  private let service = "org.neutrino.browser.chatgpt"
  private var credentials: ChatGPTCredentials?
  private var listener: OAuthLoopback?
  private var refreshTask: Task<ChatGPTCredentials, any Error>?
  private var credentialGeneration = 0
  private let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
  private let resource = "https://api.openai.com/v1"
  init() {
    // Isolated screenshot/engine acceptance must not read a real account.
    guard !CommandLine.arguments.contains("--smoke-test") else { return }
    do {
      if let data = try SecureVault.get(account: "current", service: service) {
        credentials = try JSONDecoder().decode(ChatGPTCredentials.self, from: data)
        hasSession = true
        connected = credentials?.scopes.contains("chatgpt.tokens.use.direct") == true
        email = credentials?.email
      }
    } catch { status = "The saved ChatGPT connection could not load from Keychain." }
  }
  func cancelSignIn() {
    credentialGeneration += 1
    refreshTask?.cancel()
    listener?.cancel()
    listener = nil
  }
  func signIn() async {
    guard !busy else { return }
    busy = true
    status = nil
    credentialGeneration += 1
    refreshTask?.cancel()
    let generation = credentialGeneration
    defer {
      busy = false
      listener?.cancel()
      listener = nil
    }
    do {
      let hostID: String
      if let saved = try SecureVault.get(account: "host-id", service: service),
        let value = String(data: saved, encoding: .utf8)
      {
        hostID = value
      } else {
        hostID = "urn:uuid:" + UUID().uuidString.lowercased()
        try SecureVault.put(Data(hostID.utf8), account: "host-id", service: service)
      }
      let state = try randomToken()
      let nonce = try randomToken()
      let verifier = try randomToken()
      let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
      let loopback = try OAuthLoopback()
      listener = loopback
      let callback = try await loopback.start()
      var parts = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
      let registeredID = try SecureVault.get(account: "client-id", service: service).flatMap {
        String(data: $0, encoding: .utf8)
      }
      var values = [
        "client_id": credentials?.clientID ?? registeredID ?? "dynamic_agent_client",
        "ext_agent_host_id": hostID,
        "response_type": "code", "redirect_uri": callback,
        "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
        "resource": resource, "state": state, "nonce": nonce, "code_challenge": challenge,
        "code_challenge_method": "S256",
      ]
      if let credentials {
        values["id_token_hint"] = credentials.idToken
      } else {
        values["agent_name_hint"] = "Neutrino"
      }
      parts.queryItems = values.sorted { $0.key < $1.key }.map {
        URLQueryItem(name: $0.key, value: $0.value)
      }
      guard NSWorkspace.shared.open(parts.url!) else {
        throw ValidationError("The system browser could not open the sign-in page.")
      }
      let returned = try await loopback.waitForCallback(expectedState: state)
      let issuedID = returned["client_id"] ?? values["client_id"]
      guard let clientID = issuedID, clientID != "dynamic_agent_client", clientID.count <= 256,
        let code = returned["code"], !code.isEmpty
      else {
        throw ValidationError(
          "ChatGPT registration did not return a client identity and authorization code.")
      }
      // Keep our registered identity even if the subsequent exchange fails.
      try SecureVault.put(Data(clientID.utf8), account: "client-id", service: service)
      let tokens = try await tokenRequest([
        "grant_type": "authorization_code", "client_id": clientID, "code": code,
        "code_verifier": verifier, "redirect_uri": callback, "resource": resource,
      ])
      guard let idToken = tokens["id_token"] as? String else {
        throw ValidationError("The account did not return an identity token.")
      }
      let claims = try await verifyIdentity(
        idToken, clientID: clientID, nonce: nonce, accessToken: tokens["access_token"] as? String)
      guard
        credentials == nil
          || (credentials?.subject == claims.subject && credentials?.clientID == clientID)
      else { throw ValidationError("This sign-in does not match the selected ChatGPT account.") }
      let record = try makeCredentials(
        tokens, previous: nil, clientID: clientID, subject: claims.subject,
        email: claims.email, idToken: idToken)
      guard generation == credentialGeneration else { throw CancellationError() }
      try save(record)
      status =
        connected
        ? "ChatGPT connected. Discovering available models…"
        : "Signed in, but ChatGPT plan usage was not granted. Reconnect and approve it to use AI."
      if connected {
        models = try await availableModels()
        status = "ChatGPT connected with plan usage enabled."
      }
    } catch is CancellationError { status = "Sign-in cancelled." } catch {
      status = error.localizedDescription
    }
  }
  func disconnect() async {
    guard !busy else { return }
    busy = true
    credentialGeneration += 1
    refreshTask?.cancel()
    defer { busy = false }
    do {
      let previous = credentials
      try SecureVault.delete(account: "current", service: service)
      credentials = nil
      connected = false
      hasSession = false
      email = nil
      models = []
      if let previous, let refresh = previous.refreshToken {
        let discovery = try await boundedRequest(
          URLRequest(url: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!))
        guard let body = try JSONSerialization.jsonObject(with: discovery) as? [String: Any],
          let value = body["revocation_endpoint"] as? String,
          let url = URL(string: value), url.scheme == "https", url.host == "auth.openai.com"
        else { throw ValidationError("The account's revocation endpoint is unavailable.") }
        _ = try await formRequest(
          url: url,
          values: [
            "token": refresh, "token_type_hint": "refresh_token", "client_id": previous.clientID,
          ])
      }
      status = "ChatGPT disconnected."
    } catch {
      status =
        hasSession
        ? "Could not remove the saved connection: " + error.localizedDescription
        : "Disconnected on this Mac. Account revocation could not complete: "
          + error.localizedDescription
    }
  }
  func accessToken() async throws -> String {
    guard let current = credentials, current.scopes.contains("chatgpt.tokens.use.direct") else {
      throw ValidationError("Connect ChatGPT and approve plan usage in Settings.")
    }
    if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
    if let refreshTask { return try await refreshTask.value.accessToken }
    guard let refresh = current.refreshToken else {
      throw ValidationError("Reconnect your ChatGPT account.")
    }
    let generation = credentialGeneration
    let task = Task { @MainActor in
      let tokens = try await self.tokenRequest([
        "grant_type": "refresh_token", "client_id": current.clientID, "refresh_token": refresh,
        "resource": self.resource,
      ])
      if let idToken = tokens["id_token"] as? String {
        let identity = try await self.verifyIdentity(
          idToken, clientID: current.clientID, nonce: nil,
          accessToken: tokens["access_token"] as? String)
        guard identity.subject == current.subject else {
          throw ValidationError("The refreshed identity changed accounts.")
        }
      }
      let record = try self.makeCredentials(
        tokens, previous: current, clientID: current.clientID, subject: current.subject,
        email: current.email, idToken: current.idToken)
      try Task.checkCancellation()
      guard self.credentialGeneration == generation else { throw CancellationError() }
      try self.save(record)
      return record
    }
    refreshTask = task
    defer { refreshTask = nil }
    let record = try await task.value
    return record.accessToken
  }
  func availableModels() async throws -> [String] {
    let token = try await accessToken()
    var request = URLRequest(url: URL(string: resource + "/models")!)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    let data = try await boundedRequest(request)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let models = object["models"] as? [[String: Any]]
    else { throw ValidationError("ChatGPT did not return its model catalog.") }
    return models.filter { $0["visibility"] as? String == "list" }.compactMap {
      $0["slug"] as? String
    }
  }
  func refreshModels() async {
    do { models = try await availableModels() } catch { status = error.localizedDescription }
  }
  func answer(_ text: String, model: String) async throws -> String {
    let token = try await accessToken()
    var request = URLRequest(url: URL(string: resource + "/responses")!)
    request.httpMethod = "POST"
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": model, "input": [["role": "user", "content": text]], "store": false, "stream": true,
    ])
    let options = URLSessionConfiguration.ephemeral
    options.timeoutIntervalForResource = 120
    let session = URLSession(
      configuration: options, delegate: OAuthNoRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true else {
      throw ValidationError(
        "ChatGPT rejected the request. Check model access and plan usage limits.")
    }
    var answer = ""
    var completed = false
    var received = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      received.append(byte)
      guard received.count <= 1_048_576 else {
        throw ValidationError("ChatGPT's response exceeds the size limit.")
      }
    }
    guard let stream = String(data: received, encoding: .utf8) else {
      throw ValidationError("ChatGPT returned invalid text.")
    }
    for line in stream.split(whereSeparator: \.isNewline) {
      guard line.hasPrefix("data: ") else { continue }
      let data = Data(line.dropFirst(6).utf8)
      guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      switch event["type"] as? String {
      case "response.output_text.delta": answer += event["delta"] as? String ?? ""
      case "response.completed": completed = true
      case "response.failed", "response.incomplete", "error":
        throw ValidationError("ChatGPT did not complete the response.")
      default: break
      }
    }
    guard completed else { throw ValidationError("ChatGPT's stream ended before completion.") }
    return answer
  }
  private func save(_ value: ChatGPTCredentials) throws {
    try SecureVault.put(JSONEncoder().encode(value), account: "current", service: service)
    credentials = value
    hasSession = true
    connected = value.scopes.contains("chatgpt.tokens.use.direct")
    email = value.email
  }
  private func makeCredentials(
    _ tokens: [String: Any], previous: ChatGPTCredentials?, clientID: String, subject: String,
    email: String?, idToken: String
  ) throws -> ChatGPTCredentials {
    guard let access = tokens["access_token"] as? String, !access.isEmpty,
      let tokenType = tokens["token_type"] as? String,
      tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
      let expiry = tokens["expires_in"] as? Double,
      expiry > 0, expiry <= 86400 * 30
    else { throw ValidationError("The account returned an invalid token response.") }
    let scopes =
      (tokens["scope"] as? String).map { $0.split(separator: " ").map(String.init) } ?? previous?
      .scopes ?? []
    return ChatGPTCredentials(
      clientID: clientID, subject: subject, email: email, accessToken: access,
      refreshToken: tokens["refresh_token"] as? String ?? previous?.refreshToken,
      idToken: tokens["id_token"] as? String ?? idToken, scopes: scopes,
      expiresAt: Date().addingTimeInterval(expiry))
  }
  private func tokenRequest(_ values: [String: String]) async throws -> [String: Any] {
    let data = try await formRequest(url: tokenURL, values: values)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ValidationError("The token response is invalid.")
    }
    return object
  }
  private func formRequest(url: URL, values: [String: String]) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var parts = URLComponents()
    parts.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
    request.httpBody = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(
      using: .utf8)
    return try await boundedRequest(request)
  }
  private func boundedRequest(_ request: URLRequest) async throws -> Data {
    let session = URLSession(
      configuration: .ephemeral, delegate: OAuthNoRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true else {
      throw ValidationError("The account service rejected the request. Try signing in again.")
    }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      data.append(byte)
      guard data.count <= 262144 else {
        throw ValidationError("The account response exceeds its size limit.")
      }
    }
    return data
  }
  private func verifyIdentity(_ jwt: String, clientID: String, nonce: String?, accessToken: String?)
    async throws
    -> OIDCIdentity
  {
    guard jwt.utf8.count <= 32768 else { throw ValidationError("The identity token is too large.") }
    let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3, let head = Data(base64URL: String(segments[0])),
      let body = Data(base64URL: String(segments[1])),
      let signature = Data(base64URL: String(segments[2])),
      let header = try JSONSerialization.jsonObject(with: head) as? [String: Any],
      header["alg"] as? String == "RS256", let kid = header["kid"] as? String
    else { throw ValidationError("The account returned an invalid identity token.") }
    let jwks = try await boundedRequest(
      URLRequest(url: URL(string: "https://auth.openai.com/.well-known/jwks.json")!))
    guard let object = try JSONSerialization.jsonObject(with: jwks) as? [String: Any],
      let keys = object["keys"] as? [[String: Any]],
      let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
      let n = key["n"] as? String, let e = key["e"] as? String, let modulus = Data(base64URL: n),
      let exponent = Data(base64URL: e), modulus.count >= 256, modulus.count <= 1024,
      exponent.count <= 8
    else { throw ValidationError("The account identity key could not be verified.") }
    let der = Self.der(0x30, Self.integer(modulus) + Self.integer(exponent))
    var error: Unmanaged<CFError>?
    guard
      let publicKey = SecKeyCreateWithData(
        der as CFData,
        [
          kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
          kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ] as CFDictionary, &error),
      SecKeyVerifySignature(
        publicKey, .rsaSignatureMessagePKCS1v15SHA256,
        Data((segments[0] + "." + segments[1]).utf8) as CFData, signature as CFData, &error)
    else { throw ValidationError("The account identity signature is invalid.") }
    let claims = try JSONDecoder().decode(OIDCIdentity.self, from: body)
    try claims.validate(issuer: "https://auth.openai.com", clientID: clientID, nonce: nonce)
    if let expected = claims.accessTokenHash {
      guard let accessToken,
        Data(SHA256.hash(data: Data(accessToken.utf8)).prefix(16)).base64URL == expected
      else {
        throw ValidationError("The account token does not match its verified identity.")
      }
    }
    return claims
  }
  private func randomToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw ValidationError("Secure authorization randomness is unavailable.")
    }
    return Data(bytes).base64URL
  }
  private static func integer(_ value: Data) -> Data {
    var value = Data(value.drop { $0 == 0 })
    if value.first.map({ $0 >= 128 }) == true { value.insert(0, at: 0) }
    return der(0x02, value)
  }
  private static func der(_ tag: UInt8, _ data: Data) -> Data {
    var length = [UInt8]()
    var value = data.count
    repeat {
      length.insert(UInt8(value & 255), at: 0)
      value >>= 8
    } while value > 0
    return Data(
      [tag] + (data.count < 128 ? [UInt8(data.count)] : [0x80 | UInt8(length.count)] + length))
      + data
  }
}

private final class OAuthNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
extension Data {
  fileprivate var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
      of: "/", with: "_"
    ).replacingOccurrences(of: "=", with: "")
  }
  fileprivate init?(base64URL: String) {
    var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    self.init(base64Encoded: value)
  }
}

@MainActor private final class OAuthLoopback {
  private let listener: NWListener
  private var pending: CheckedContinuation<[String: String], any Error>?
  private var expectedState: String?
  private var timeout: Task<Void, Never>?
  private var earlyCallback: [String: String]?
  private var readiness: CheckedContinuation<Void, any Error>?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var connectionDeadlines: [ObjectIdentifier: Task<Void, Never>] = [:]
  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters, on: .any)
  }
  func start() async throws -> String {
    try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
      readiness = ready
      listener.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in
          guard let self, let readiness = self.readiness else { return }
          switch state {
          case .ready:
            self.readiness = nil
            readiness.resume()
          case .failed(let error):
            self.readiness = nil
            readiness.resume(throwing: error)
          case .cancelled:
            self.readiness = nil
            readiness.resume(throwing: CancellationError())
          default: break
          }
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in self?.accept(connection) }
      }
      listener.start(queue: .main)
    }
    guard let port = listener.port else {
      throw ValidationError("The sign-in callback could not bind a port.")
    }
    return "http://127.0.0.1:\(port.rawValue)/auth/callback"
  }
  func waitForCallback(expectedState: String) async throws -> [String: String] {
    self.expectedState = expectedState
    if let earlyCallback { return try validate(earlyCallback) }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        pending = $0
        timeout = Task { @MainActor in
          do {
            try await Task.sleep(for: .seconds(300))
            cancel()
          } catch {}
        }
      }
    } onCancel: {
      Task { @MainActor in self.cancel() }
    }
  }
  func cancel() {
    timeout?.cancel()
    timeout = nil
    listener.cancel()
    for connection in Array(connections.values) { closeConnection(connection) }
    pending?.resume(throwing: CancellationError())
    pending = nil
  }
  private func validate(_ values: [String: String]) throws -> [String: String] {
    guard values["state"] == expectedState else {
      throw ValidationError("The sign-in callback state is invalid.")
    }
    guard values["error"] == nil else { throw ValidationError("ChatGPT sign-in was not approved.") }
    return values
  }
  private func accept(_ connection: NWConnection) {
    guard connections.count < 8 else {
      connection.cancel()
      return
    }
    let id = ObjectIdentifier(connection)
    connections[id] = connection
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      Task { @MainActor in
        guard let self, let connection else { return }
        switch state {
        case .failed, .cancelled: self.closeConnection(connection)
        default: break
        }
      }
    }
    connectionDeadlines[id] = Task { @MainActor [weak self, weak connection] in
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      if let connection { self?.closeConnection(connection) }
    }
    connection.start(queue: .main)
    receive(connection, data: Data())
  }
  private func closeConnection(_ connection: NWConnection) {
    let id = ObjectIdentifier(connection)
    connectionDeadlines.removeValue(forKey: id)?.cancel()
    connections.removeValue(forKey: id)
    connection.stateUpdateHandler = nil
    connection.cancel()
  }
  private func receive(_ connection: NWConnection, data: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - data.count) {
      [weak self] chunk, _, complete, error in
      Task { @MainActor in
        guard let self else {
          connection.cancel()
          return
        }
        var bytes = data
        if let chunk { bytes.append(chunk) }
        guard bytes.count < 8192, error == nil, let request = String(data: bytes, encoding: .utf8)
        else {
          connection.cancel()
          return
        }
        guard request.contains("\r\n\r\n") else {
          if complete { connection.cancel() } else { self.receive(connection, data: bytes) }
          return
        }
        let first = request.components(separatedBy: "\r\n")[0].split(separator: " ")
        guard first.count == 3, first[0] == "GET",
          let url = URLComponents(string: "http://127.0.0.1" + first[1]),
          url.path == "/auth/callback"
        else {
          connection.cancel()
          return
        }
        var values = [String: String]()
        for item in url.queryItems ?? [] {
          guard values[item.name] == nil else {
            connection.cancel()
            return
          }
          values[item.name] = item.value ?? ""
        }
        if let expectedState = self.expectedState, values["state"] != expectedState {
          connection.cancel()
          return
        }
        let response =
          "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\n\r\nReturn to Neutrino to finish connecting your account."
        connection.send(
          content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        guard let pending = self.pending else {
          self.earlyCallback = values
          return
        }
        self.pending = nil
        self.timeout?.cancel()
        self.listener.cancel()
        do { pending.resume(returning: try self.validate(values)) } catch {
          pending.resume(throwing: error)
        }
      }
    }
  }
}
