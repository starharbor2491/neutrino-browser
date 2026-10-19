// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct TabFolder: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var collapsed: Bool
  /// One of the tab-group colors: grey, blue, red, yellow, green, pink, purple, cyan.
  public var color: String?
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
  /// A letter or emoji shown for the Space instead of its initial.
  public var emoji: String?
  /// Two hex colors for the Space's background, top to bottom.
  public var gradient: [String]?
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
  public mutating func normalize() { if let value = try? RustCore.transform(self, operation: "normalizeSpace") { self=value } }
  public mutating func archiveIdleTabs(before date: Date) {
    if let value = try? RustCore.decode(Self.self,from:RustCore.request(["op":"archiveIdleTabs","value":RustCore.encoded(self),"before":date.timeIntervalSinceReferenceDate])) { self=value }
  }
  @discardableResult public mutating func restoreArchivedTab(_ id:UUID) -> Bool {
    guard let result=try? RustCore.request(["op":"restoreArchivedTab","value":RustCore.encoded(self),"id":id.uuidString]) as? [String:Any],
      let value=result["value"], let updated=try? RustCore.decode(Self.self,from:value) else { return false }
    self=updated;return result["changed"] as? Bool ?? false
  }
}
extension LibraryState {
  public mutating func normalizeSpaces() {if let value=try? RustCore.transform(self,operation:"normalizeSpaces") {self=value}}
  public func configuration(for spaceID: UUID?) -> Configuration {
    do {
      let projection:[String:Any]=["spaces":(spaces ?? []).map{["id":$0.id.uuidString,"setupID":$0.setupID?.uuidString as Any? ?? NSNull()]},
        "preferences":["configuration":try RustCore.encoded(preferences.configuration),"savedConfigurations":try RustCore.encoded(preferences.savedConfigurations)]]
      return try RustCore.decode(Configuration.self,from:RustCore.request(["op":"spaceConfiguration","value":projection,"id":spaceID?.uuidString as Any? ?? NSNull()]))
    } catch {return preferences.configuration}
  }
}

/// Value-semantic ownership registry: claiming a live tab returns its previous
/// window so the host can transfer the existing native view without reloading.
public struct LiveTabOwnership: Sendable {
  private var owners: [String:String] = [:]
  public init() {}
  public func owner(of tab: UUID) -> UUID? {owners[tab.uuidString].flatMap(UUID.init(uuidString:))}
  @discardableResult public mutating func claim(_ tab: UUID,in window: UUID) -> UUID? {update(tab,in:window,action:"claim")}
  public mutating func release(_ tab: UUID,from window: UUID) {_ = update(tab,in:window,action:"release")}
  private mutating func update(_ tab:UUID,in window:UUID,action:String) -> UUID? {
    guard let result=try? RustCore.request(["op":"liveTabOwnership","value":owners,"tab":tab.uuidString,"window":window.uuidString,"action":action]) as? [String:Any],let updated=result["owners"] as? [String:String] else {return nil}
    owners=updated;return (result["owner"] as? String).flatMap(UUID.init(uuidString:))
  }
}
