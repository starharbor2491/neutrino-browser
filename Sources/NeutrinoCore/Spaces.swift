// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct TabFolder: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var collapsed: Bool
  public init(id: UUID = UUID(), name: String, collapsed: Bool = false) {
    self.id = id
    self.name = name
    self.collapsed = collapsed
  }
}

/// Spaces own organization. Profiles own website identity; window sessions only
/// record the selected tab and presentation of a shared Space.
public struct BrowserSpace: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var symbol: String
  public var profileID: UUID
  public var setupID: UUID?
  public var tabs: [BrowserTab]
  public var folders: [TabFolder]
  public var archivedTabs: [BrowserTab]
  public init(
    id: UUID = UUID(), name: String, symbol: String = "circle.grid.2x2", profileID: UUID,
    tabs: [BrowserTab] = []
  ) {
    self.id = id
    self.name = name
    self.symbol = symbol
    self.profileID = profileID
    self.tabs = tabs.isEmpty ? [BrowserTab(engineID: .chromium)] : tabs
    folders = []
    archivedTabs = []
  }
  public mutating func normalize() {
    name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    if name.isEmpty { name = "Space" }
    if symbol.count > 80 || symbol.isEmpty { symbol = "circle.grid.2x2" }
    var session = WindowSession(profileID: profileID, tabs: tabs)
    session.normalize()
    tabs = session.tabs
    var seen = Set<UUID>()
    folders = Array(folders.filter { seen.insert($0.id).inserted }.prefix(100))
    for i in folders.indices { folders[i].name = String(folders[i].name.prefix(80)) }
    let ids = Set(folders.map(\.id))
    for i in tabs.indices where tabs[i].folderID.map({ !ids.contains($0) }) == true {
      tabs[i].folderID = nil
    }
    var archived = WindowSession(profileID: profileID, tabs: archivedTabs)
    if !archivedTabs.isEmpty {
      archived.normalize()
      archivedTabs = archived.tabs.filter { !tabs.map(\.id).contains($0.id) }
    }
  }
  public mutating func archiveIdleTabs(before date: Date) {
    let idle = tabs.filter {
      !$0.pinned && $0.folderID == nil && $0.lastUsedAt.map { $0 < date } == true
    }
    archivedTabs.append(contentsOf: idle)
    tabs.removeAll { tab in idle.contains { $0.id == tab.id } }
    if tabs.isEmpty { tabs = [BrowserTab(engineID: idle.first?.engineID ?? .chromium)] }
    archivedTabs = Array(archivedTabs.suffix(200))
  }
  @discardableResult public mutating func restoreArchivedTab(_ id: UUID) -> Bool {
    guard tabs.count < 200, let index = archivedTabs.firstIndex(where: { $0.id == id }) else {
      return false
    }
    var tab = archivedTabs.remove(at: index)
    tab.lastUsedAt = Date()
    tab.parentID = nil
    tabs.append(tab)
    return true
  }
}

extension LibraryState {
  public mutating func normalizeSpaces() {
    let profileIDs = Set(profiles.map(\.id))
    let setupIDs = Set(preferences.savedConfigurations.map(\.id))
    var seen = Set<UUID>()
    var valid = Array(
      (spaces ?? []).filter { profileIDs.contains($0.profileID) && seen.insert($0.id).inserted }
        .prefix(100))
    if valid.isEmpty {
      valid = [BrowserSpace(name: "Personal", profileID: profiles[0].id,
        tabs: [BrowserTab(engineID: profiles[0].engineID ?? .chromium)])]
    }
    var usedTabIDs = Set<UUID>()
    for i in valid.indices {
      valid[i].normalize()
      var remapped = [UUID: UUID]()
      for tabIndex in valid[i].tabs.indices {
        let original = valid[i].tabs[tabIndex].id
        if !usedTabIDs.insert(original).inserted {
          let replacement = UUID()
          valid[i].tabs[tabIndex].id = replacement
          usedTabIDs.insert(replacement)
          remapped[original] = replacement
        }
      }
      for tabIndex in valid[i].tabs.indices {
        if let parent = valid[i].tabs[tabIndex].parentID, let replacement = remapped[parent] {
          valid[i].tabs[tabIndex].parentID = replacement
        }
      }
      for tabIndex in valid[i].archivedTabs.indices {
        if !usedTabIDs.insert(valid[i].archivedTabs[tabIndex].id).inserted {
          let replacement = UUID()
          valid[i].archivedTabs[tabIndex].id = replacement
          usedTabIDs.insert(replacement)
        }
      }
      if valid[i].setupID.map({ !setupIDs.contains($0) }) == true { valid[i].setupID = nil }
    }
    spaces = valid
    for i in sessions.indices {
      guard let space = valid.first(where: { $0.id == sessions[i].spaceID }) else { continue }
      sessions[i].profileID = space.profileID
      sessions[i].tabs = space.tabs
      sessions[i].normalize()
    }
  }
  public func configuration(for spaceID: UUID?) -> Configuration {
    guard let space = spaces?.first(where: { $0.id == spaceID }),
      let setup = preferences.savedConfigurations.first(where: { $0.id == space.setupID })
    else { return preferences.configuration }
    return setup.configuration
  }
}

/// Value-semantic ownership registry: claiming a live tab returns its previous
/// window so the host can transfer the existing native view without reloading.
public struct LiveTabOwnership: Sendable {
  private var owners: [UUID: UUID] = [:]
  public init() {}
  public func owner(of tab: UUID) -> UUID? { owners[tab] }
  @discardableResult public mutating func claim(_ tab: UUID, in window: UUID) -> UUID? {
    owners.updateValue(window, forKey: tab)
  }
  public mutating func release(_ tab: UUID, from window: UUID) {
    if owners[tab] == window { owners.removeValue(forKey: tab) }
  }
}
