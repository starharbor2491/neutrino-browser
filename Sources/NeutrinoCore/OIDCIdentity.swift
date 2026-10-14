// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Claim validation follows signature verification by the account adapter.
/// JSONDecoder rejects booleans and strings where numeric dates are required.
public struct OIDCIdentity: Codable, Sendable {
  public let issuer: String
  public let subject: String
  public let audiences: [String]
  public let authorizedParty: String?
  public let nonce: String?
  public let expiresAt: Double
  public let issuedAt: Double
  public let notBefore: Double?
  public let email: String?
  public let accessTokenHash: String?

  private enum CodingKeys: String, CodingKey {
    case issuer = "iss"
    case subject = "sub"
    case audiences = "aud"
    case authorizedParty = "azp"
    case nonce
    case expiresAt = "exp"
    case issuedAt = "iat"
    case notBefore = "nbf"
    case email
    case accessTokenHash = "at_hash"
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    issuer = try values.decode(String.self, forKey: .issuer)
    subject = try values.decode(String.self, forKey: .subject)
    if let single = try? values.decode(String.self, forKey: .audiences) {
      audiences = [single]
    } else {
      audiences = try values.decode([String].self, forKey: .audiences)
    }
    authorizedParty = try values.decodeIfPresent(String.self, forKey: .authorizedParty)
    nonce = try values.decodeIfPresent(String.self, forKey: .nonce)
    expiresAt = try values.decode(Double.self, forKey: .expiresAt)
    issuedAt = try values.decode(Double.self, forKey: .issuedAt)
    notBefore = try values.decodeIfPresent(Double.self, forKey: .notBefore)
    email = try values.decodeIfPresent(String.self, forKey: .email)
    accessTokenHash = try values.decodeIfPresent(String.self, forKey: .accessTokenHash)
  }
  public func validate(
    issuer: String, clientID: String, nonce: String?, subject: String? = nil, now: Date = Date()
  ) throws {
    _ = try RustCore.policy(["op":"validateIdentity","value":RustCore.encoded(self),"issuer":issuer,"clientID":clientID,
      "nonce":nonce as Any? ?? NSNull(),"subject":subject as Any? ?? NSNull(),"now":now.timeIntervalSince1970])
  }
}
