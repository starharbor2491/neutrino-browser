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
    _ = try RustCore.request(["op": "validateAI", "provider": provider.rawValue, "endpoint": endpoint, "model": model])
    guard let url = URL(string: endpoint) else { throw ValidationError("Invalid AI endpoint.") }
    return url
  }
}
