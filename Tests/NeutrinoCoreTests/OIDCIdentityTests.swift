// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import NeutrinoCore

private let identityTime = Date(timeIntervalSince1970: 1_800_000_000)
private func identity(_ changes: [String: Any] = [:]) throws -> OIDCIdentity {
  var claims: [String: Any] = [
    "iss": "https://auth.openai.com", "sub": "user", "aud": "neutrino-client",
    "nonce": "random-nonce", "iat": 1_799_999_900, "exp": 1_800_000_100,
  ]
  claims.merge(changes) { _, new in new }
  return try JSONDecoder().decode(
    OIDCIdentity.self, from: JSONSerialization.data(withJSONObject: claims))
}
private func validate(_ claims: OIDCIdentity, subject: String? = nil) throws {
  try claims.validate(
    issuer: "https://auth.openai.com", clientID: "neutrino-client", nonce: "random-nonce",
    subject: subject, now: identityTime)
}
@Test func accountIdentityRequiresTheExpectedIssuerAudienceNonceAndSubject() throws {
  try validate(identity())
  for claims in [
    ["iss": "https://evil.example"], ["aud": "other-client"], ["nonce": "old-nonce"], ["sub": ""],
  ] {
    #expect(throws: ValidationError.self) { try validate(identity(claims)) }
  }
  #expect(throws: ValidationError.self) { try validate(identity(), subject: "other-user") }
}
@Test func multipleIdentityAudiencesRequireOurAuthorizedParty() throws {
  #expect(throws: ValidationError.self) {
    try validate(identity(["aud": ["neutrino-client", "another-client"]]))
  }
  try validate(identity(["aud": ["neutrino-client", "another-client"], "azp": "neutrino-client"]))
  #expect(throws: ValidationError.self) { try validate(identity(["azp": "another-client"])) }
}
@Test func identityDatesRejectExpiredFutureAndMalformedClaims() throws {
  for claims: [String: Any] in [
    ["exp": 1_800_000_000], ["iat": 1_800_000_061], ["nbf": 1_800_000_061],
  ] {
    #expect(throws: ValidationError.self) { try validate(identity(claims)) }
  }
  #expect(throws: DecodingError.self) { try identity(["exp": true]) }
  #expect(throws: DecodingError.self) { try identity(["iat": "1799999900"]) }
}
