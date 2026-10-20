// SPDX-License-Identifier: MPL-2.0
import Foundation
import NeutrinoCore
import Security

/// Secrets never enter the SQLite library, setup packs, logs, or module data.
enum SecureVault {
  static func put(_ value: Data, account: String, service: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
    ]
    let update = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw failure(update) }
    var item = query
    item[kSecValueData as String] = value
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw failure(status) }
  }
  static func get(account: String, service: String) throws -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw failure(status) }
    return result as? Data
  }
  static func accounts(service: String) throws -> [String] {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(
      [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
      ] as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw failure(status) }
    return (result as? [[String: Any]] ?? []).compactMap {
      $0[kSecAttrAccount as String] as? String
    }
  }
  static func delete(account: String? = nil, service: String) throws {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
    ]
    if let account { query[kSecAttrAccount as String] = account }
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
  }
  private static func failure(_ code: OSStatus) -> ValidationError {
    ValidationError(
      (SecCopyErrorMessageString(code, nil) as String?)
        ?? "The macOS Keychain could not complete this request.")
  }
}

struct LocalCredential: Codable, Identifiable {
  var origin: String
  var username: String
  var password: String
  var id: String { origin + "\n" + username }
  static func origin(for url: URL) throws -> String {
    guard AddressResolver.isWebURL(url), let host = url.host else {
      throw ValidationError("Choose a website address for this password.")
    }
    var parts = URLComponents()
    parts.scheme = url.scheme?.lowercased()
    parts.host = host.lowercased()
    if let port = url.port,
      !((parts.scheme == "https" && port == 443) || (parts.scheme == "http" && port == 80))
    {
      parts.port = port
    }
    return parts.string!
  }
  static func service(_ profile: UUID) -> String {
    "org.neutrino.browser.passwords." + profile.uuidString
  }
  static func list(profile: UUID) throws -> [LocalCredential] {
    try SecureVault.accounts(service: service(profile)).compactMap { account in
      guard let data = try SecureVault.get(account: account, service: service(profile)) else {
        return nil
      }
      return try JSONDecoder().decode(Self.self, from: data)
    }.sorted { $0.origin < $1.origin }
  }
  func save(profile: UUID) throws {
    guard !username.contains("\n"), username.count <= 500, password.utf8.count <= 8192,
      !password.isEmpty
    else { throw ValidationError("Enter a valid username and password.") }
    try SecureVault.put(JSONEncoder().encode(self), account: id, service: Self.service(profile))
  }
}

/// A payment card kept in Keychain, separate for each Profile. The security code is never stored.
struct LocalCard: Codable, Identifiable {
  var id: String
  var name: String
  var number: String
  var month: Int
  var year: Int
  static func service(_ profile: UUID) -> String { "org.neutrino.browser.cards." + profile.uuidString }
  static func list(profile: UUID) -> [LocalCard] {
    ((try? SecureVault.accounts(service: service(profile))) ?? []).compactMap { account in
      (try? SecureVault.get(account: account, service: service(profile))).flatMap { $0 }.flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }.sorted { $0.name < $1.name }
  }
  func save(profile: UUID) throws {
    guard (12...19).contains(number.count), number.allSatisfy(\.isNumber), (1...12).contains(month), (2000...2100).contains(year), name.count <= 80
    else { throw ValidationError("Check the card details.") }
    try SecureVault.put(JSONEncoder().encode(self), account: id, service: Self.service(profile))
  }
  /// What the interface may show: never the full number.
  var summary: [String: String] {
    ["id": id, "name": name.isEmpty ? "Card" : name, "last4": String(number.suffix(4)), "expiry": String(format: "%02d/%02d", month, year % 100)]
  }
}
