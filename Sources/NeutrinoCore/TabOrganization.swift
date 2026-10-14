// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct TabOrganization: Codable, Equatable, Sendable {
  public struct Folder: Codable, Equatable, Sendable {
    public var name: String
    public var tabIDs: [UUID]
  }
  public var folders: [Folder]
  public static func decode(_ data: Data, knownTabs: Set<UUID>) throws -> Self {
    guard data.count <= 65536 else {
      throw ValidationError("The organization proposal is too large.")
    }
    let proposal = try JSONDecoder().decode(Self.self, from: data)
    _ = try RustCore.request(["op": "validateOrganization", "proposal": try JSONSerialization.jsonObject(with: data), "knownTabs": knownTabs.map(\.uuidString)])
    return proposal
  }
  public func apply(to space: inout BrowserSpace) throws {
    space=try RustCore.decode(BrowserSpace.self,from:RustCore.request(["op":"applyOrganization","value":RustCore.encoded(space),"proposal":RustCore.encoded(self)]))
  }
}
