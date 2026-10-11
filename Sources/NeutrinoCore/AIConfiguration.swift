// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum AIProvider: String, Codable, CaseIterable, Sendable {
  case openAI, xAI, local
  public var label: String {
    switch self {
    case .openAI: "OpenAI"
    case .xAI: "xAI"
    case .local: "Local model"
    }
  }
  public var endpoint: String {
    switch self {
    case .openAI: "https://api.openai.com/v1"
    case .xAI: "https://api.x.ai/v1"
    case .local: "http://localhost:1234/v1"
    }
  }
}
public struct AIConfiguration: Codable, Equatable, Sendable {
  public var provider: AIProvider
  public var endpoint: String
  public var model: String
  public var useAccount: Bool?
  public init(provider: AIProvider, endpoint: String, model: String) {
    self.provider = provider
    self.endpoint = endpoint
    self.model = model
  }
  public func validatedEndpoint() throws -> URL {
    guard let url = URL(string: endpoint), let host = url.host?.lowercased(),
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      model.count <= 200, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw ValidationError("Enter a valid AI endpoint and model name.") }
    let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    guard url.scheme == "https" || (provider == .local && url.scheme == "http" && loopback) else {
      throw ValidationError("Use HTTPS for remote models, or HTTP on localhost for a local model.")
    }
    if provider == .openAI && host != "api.openai.com" {
      throw ValidationError("OpenAI keys can only be sent to api.openai.com.")
    }
    if provider == .xAI && host != "api.x.ai" {
      throw ValidationError("xAI keys can only be sent to api.x.ai.")
    }
    return url
  }
}
