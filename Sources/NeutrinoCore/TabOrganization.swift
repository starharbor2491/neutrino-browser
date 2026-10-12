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
    _ = try Self.decode(JSONEncoder().encode(self), knownTabs: Set(space.tabs.map(\.id)))
    guard space.folders.count + folders.count <= 100 else {
      throw ValidationError("This Space already has too many folders.")
    }
    for folder in folders {
      let item = TabFolder(name: folder.name)
      space.folders.append(item)
      for i in space.tabs.indices where folder.tabIDs.contains(space.tabs[i].id) {
        space.tabs[i].folderID = item.id
      }
    }
  }
}
