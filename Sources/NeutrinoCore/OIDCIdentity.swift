// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Claim validation follows signature verification by the account adapter.
/// JSONDecoder rejects booleans and strings where numeric dates are required.
public struct OIDCIdentity: Decodable, Sendable {
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
    let time = now.timeIntervalSince1970
    guard self.issuer == issuer, !self.subject.isEmpty, self.subject.utf8.count <= 256,
      subject == nil || self.subject == subject,
      !audiences.isEmpty, audiences.count <= 20, audiences.contains(clientID),
      (audiences.count == 1 && authorizedParty == nil) || authorizedParty == clientID,
      nonce == nil || self.nonce == nonce,
      expiresAt.isFinite, issuedAt.isFinite, expiresAt > time,
      issuedAt > 0, issuedAt <= time + 60, expiresAt > issuedAt,
      notBefore == nil || (notBefore!.isFinite && notBefore! <= time + 60)
    else {
      throw ValidationError("The account identity claims do not match this authorization.")
    }
  }
}
