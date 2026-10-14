// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum SearchProvider: String, Codable, CaseIterable, Sendable {
    case duckDuckGo, google, bing
    public var label: String {
        switch self { case .duckDuckGo: "DuckDuckGo"; case .google: "Google"; case .bing: "Bing" }
    }

}

public enum AddressResolver {
    /// Navigation policy lives in Rust and is shared with the interface reducer.
    public static func resolve(_ input: String, search: SearchProvider = .duckDuckGo) -> URL? {
        guard let value = try? RustCore.request(["op": "resolveAddress", "input": input, "search": search.rawValue]) as? String else { return nil }
        return URL(string: value)
    }
    public static func isWebURL(_ url: URL) -> Bool {
        (try? RustCore.request(["op": "isWebURL", "url": url.absoluteString]) as? Bool) ?? false
    }
}

/// Website titles are limited to 512 Unicode scalars and at most 2048 UTF-8
/// bytes; grapheme counts alone do not bound combining-character input.
public func boundedPageTitle(_ title: String) -> String {
    (try? RustCore.request(["op": "pageTitle", "title": title]) as? String) ?? "Website"
}

public enum BrowserEngineID: String, Codable, CaseIterable, Sendable {
    case webkit, chromium
    public var label: String { self == .webkit ? "WebKit" : "Blink" }
}
/// Safe restoration data for Chrome's tabs within one native browser pane.
public struct ChromiumSessionPage: Codable, Equatable, Sendable {
    public var url: URL?
    public var title: String
    public init(url: URL? = nil, title: String = "New tab") { self.url = url; self.title = title }
    /// The selected page is first. Blank/internal pages retain their slot without
    /// persisting privileged URLs, cookies, forms or website execution state.
    public static func normalized(_ pages: [Self]) -> [Self] {
        (try? RustCore.transform(pages, operation: "normalizeChromiumPages")) ?? []
    }
}
public struct BrowserTab: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL?
    public var pinned: Bool
    public var parentID: UUID?
    public var collapsed: Bool?
    public var engineID: BrowserEngineID?
    public var faviconDataURL: String?
    public var chromiumPages: [ChromiumSessionPage]?
    public var folderID: UUID?
    public var lastUsedAt: Date?
    public init(id: UUID = UUID(), title: String = "New tab", url: URL? = nil, pinned: Bool = false, parentID: UUID? = nil, engineID: BrowserEngineID? = nil, chromiumPages: [ChromiumSessionPage]? = nil) {
        self.id = id; self.title = title; self.url = url; self.pinned = pinned; self.parentID = parentID; self.engineID = engineID; self.chromiumPages = chromiumPages
    }
}
public struct TabSplit: Codable, Equatable, Sendable {
    public var first: UUID
    public var second: UUID
    public init(first: UUID, second: UUID) { self.first = first; self.second = second }
    public func contains(_ id: UUID) -> Bool { first == id || second == id }
}
public struct WindowSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var profileID: UUID
    public var tabs: [BrowserTab]
    public var selectedTabID: UUID
    public var split: TabSplit?
    public var splitSuppressed: Bool?
    public var spaceID: UUID?
    public init(id: UUID = UUID(), profileID: UUID, tabs: [BrowserTab] = []) {
        self.id = id; self.profileID = profileID
        self.tabs = tabs.isEmpty ? [BrowserTab()] : tabs
        self.selectedTabID = self.tabs[0].id
    }
    public mutating func normalize() { if let value = try? RustCore.transform(self, operation: "normalizeSession") { self = value } }
    public func ancestors(of id: UUID) -> [UUID] {
        (try? RustCore.decode([UUID].self, from: RustCore.request(["op":"sessionAncestors","value":RustCore.encoded(self),"id":id.uuidString]))) ?? []
    }
    public var visibleTreeTabs: [BrowserTab] {
        (try? RustCore.decode([BrowserTab].self, from: RustCore.request(["op":"visibleTreeTabs","value":RustCore.encoded(self)]))) ?? []
    }
    @discardableResult public mutating func setParent(_ id: UUID, to parent: UUID?) -> Bool {
        guard let result = try? RustCore.request(["op":"setTabParent","value":RustCore.encoded(self),"id":id.uuidString,"parentID":parent?.uuidString as Any? ?? NSNull()]) as? [String:Any],
              let value = result["value"], let updated = try? RustCore.decode(Self.self, from:value) else { return false }
        self = updated; return result["changed"] as? Bool ?? false
    }
    public mutating func selectTab(_ id: UUID) {
        if let value = try? RustCore.decode(Self.self, from:RustCore.request(["op":"selectSessionTab","value":RustCore.encoded(self),"id":id.uuidString])) { self=value }
    }
    public mutating func enableSplit(defaultEngine: BrowserEngineID = .chromium) {
        if let value = try? RustCore.decode(Self.self, from:RustCore.request(["op":"enableSessionSplit","value":RustCore.encoded(self),"engine":defaultEngine.rawValue])) {self=value}
    }
}
public struct Profile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var engineID: BrowserEngineID?
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name; engineID = .chromium }
}
public struct Bookmark: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var profileID: UUID
    public var title: String
    public var url: URL
    public var createdAt: Date
    public init(id: UUID = UUID(), profileID: UUID, title: String, url: URL, createdAt: Date = Date()) {
        self.id = id; self.profileID = profileID; self.title = title; self.url = url; self.createdAt = createdAt
    }
}
public struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var profileID: UUID
    public var title: String
    public var url: URL
    public var visitedAt: Date
    public init(id: UUID = UUID(), profileID: UUID, title: String, url: URL, visitedAt: Date = Date()) {
        self.id = id; self.profileID = profileID; self.title = title; self.url = url; self.visitedAt = visitedAt
    }
}
public struct Note: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var profileID: UUID
    public var title: String
    public var text: String
    public var modifiedAt: Date
    public var spaceID: UUID?
    public var sourceURL: URL?
    public var sourceTitle: String?
    public var sourceTabID: UUID?
    public var quotedText: String?
    public init(id: UUID = UUID(), profileID: UUID, title: String = "Untitled note", text: String = "") {
        self.id = id; self.profileID = profileID; self.title = title; self.text = text; self.modifiedAt = Date()
    }
}

public enum DesignSystem: String, Codable, CaseIterable, Sendable {
    case native, material, liquidGlass, graphite
    public var label: String {
        switch self { case .native: "macOS"; case .material: "Material"; case .liquidGlass: "Liquid Glass"; case .graphite: "Graphite" }
    }
}
public enum ColorMode: String, Codable, CaseIterable, Sendable { case system, light, dark }
public enum Accent: String, Codable, CaseIterable, Sendable { case blue, teal, orange, purple, pink, rose }
public enum Density: String, Codable, CaseIterable, Sendable { case comfortable, compact }
public enum TabPlacement: String, Codable, CaseIterable, Sendable { case top, bottom, leading, trailing }
public enum BarPlacement: String, Codable, CaseIterable, Sendable { case top, bottom }
public enum SidebarPlacement: String, Codable, CaseIterable, Sendable { case leading, trailing, hidden }
public enum SplitAxis: String, Codable, CaseIterable, Sendable { case sideBySide, stacked }
public enum InterfaceTypeface: String, Codable, CaseIterable, Sendable { case system, rounded, serif, monospaced }
public struct ComponentAppearance: Codable, Equatable, Sendable {
    public var density: Density?
    public var fontScale: Double?
    public var cornerRadius: Double?
    public init() {}

}
public enum ToolbarRegion: String, Codable, CaseIterable, Sendable {
    case beforeAddress, afterAddress, top, bottom, overflow
    public var label: String {
        switch self { case .beforeAddress: "Before address"; case .afterAddress: "After address"; case .top: "Top toolbar"; case .bottom: "Bottom toolbar"; case .overflow: "Browser menu" }
    }
}
public enum ToolbarCommand: String, Codable, CaseIterable, Sendable {
    case back, forward, reload, newTab, home, bookmark, sidebar, reader, screenshot, focus, downloads, modules, customize, settings, separator
    public var label: String {
        switch self {
        case .back: "Back"; case .forward: "Forward"; case .reload: "Reload or stop"; case .newTab: "New tab"; case .home: "Start page"; case .bookmark: "Bookmark page"; case .sidebar: "Sidebar panels"; case .reader: "Reader"; case .screenshot: "Capture page"; case .focus: "Focus mode"; case .downloads: "Downloads"; case .modules: "Modules"; case .customize: "Customize"; case .settings: "Settings"; case .separator: "Separator"
        }
    }
}
public struct ToolbarComponent: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var command: ToolbarCommand
    public var region: ToolbarRegion
    public init(id: UUID = UUID(), command: ToolbarCommand, region: ToolbarRegion) { self.id = id; self.command = command; self.region = region }
}
public struct Theme: Codable, Equatable, Sendable {
    public var design: DesignSystem = .graphite
    public var colorMode: ColorMode = .dark
    public var accent: Accent = .purple
    public var density: Density = .comfortable
    public var cornerRadius: Double = 6
    public var transparency: Bool = false
    public var reducedMotion: Bool = false
    // Optional fields preserve decoding of existing user configurations and setup packs.
    public var typography: InterfaceTypeface?
    public var fontScale: Double?
    public var spacingScale: Double?
    public var accentHex: String?
    public var surfaceHex: String?
    public var textHex: String?
    public var borderWidth: Double?
    public var shadowStrength: Double?
    public var iconPack: String?
    public var iconStroke: Double?
    public var preset: String?
    public var tabsAppearance: ComponentAppearance?
    public var navigationAppearance: ComponentAppearance?
    public var sidebarAppearance: ComponentAppearance?
    public init() {}
    public mutating func normalize() {
        if let normalized = try? RustCore.transform(self, operation: "normalizeTheme") { self = normalized }
    }
}
public struct BrowserLayout: Codable, Equatable, Sendable {
    public var tabs: TabPlacement = .leading
    public var navigation: BarPlacement = .top
    public var sidebar: SidebarPlacement = .leading
    public var sidebarWidth: Double = 240
    public var bookmarksBar: Bool = false
    public var statusBar: Bool = false
    public var treeTabs: Bool?
    public var split: SplitAxis?
    public var toolbarComponents: [ToolbarComponent]?
    public var addressWidth: Double?
    public var tabsWidth: Double?
    public var hideTabStrip: Bool?
    public var sidebarAutoHide: Bool?
    public var secondaryPanel: String?
    public init() {}
    public mutating func normalize() {
        if let normalized = try? RustCore.transform(self, operation: "normalizeLayout") { self = normalized }
    }
}
public struct Configuration: Codable, Equatable, Sendable {
    public var theme = Theme()
    public var layout = BrowserLayout()
    public init() {}
    public mutating func normalize() { theme.normalize(); layout.normalize() }
}
public struct NamedConfiguration: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var configuration: Configuration
    public var requiredModuleIDs: [String]?
    public init(id: UUID = UUID(), name: String, configuration: Configuration) {
        self.id = id; self.name = name; self.configuration = configuration
    }
}
public struct Preferences: Codable, Equatable, Sendable {
    public var search: SearchProvider = .duckDuckGo
    public var restoreSession: Bool = true
    public var blockPopups: Bool = true
    public var configuration = Configuration()
    public var savedConfigurations: [NamedConfiguration] = []
    public var completedOnboarding: Bool = false
    public var blockTrackers: Bool?
    public var autoArchiveDays: Int?
    public var ai: AIConfiguration?
    public init() {}
}
public struct LibraryState: Codable, Equatable, Sendable {
    public var profiles: [Profile] = [Profile(name: "Personal")]
    public var bookmarks: [Bookmark] = []
    public var history: [HistoryEntry] = []
    public var notes: [Note] = []
    public var sessions: [WindowSession] = []
    public var spaces: [BrowserSpace]?
    public var pendingProfileDeletions: [UUID]?
    public var pendingWebsiteDataClears: [UUID]?
    public var preferences = Preferences()
    public init() { spaces = [BrowserSpace(name: "Personal", profileID: profiles[0].id)] }
    public mutating func normalize() {
        if let value = try? RustCore.transform(self, operation: "normalizeLibrary") { self = value }
    }
}

/// Intentionally excludes browsing data, credentials, module grants and executable content.
public struct SetupPack: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public var name: String
    public var configuration: Configuration
    public var requiredModuleIDs: [String]?
    public init(name: String, configuration: Configuration, requiredModuleIDs: [String]? = nil) {
        formatVersion = 1; self.name = name; self.configuration = configuration; self.requiredModuleIDs = requiredModuleIDs
    }
    public static func decode(_ data: Data) throws -> SetupPack {
        guard data.count <= 64 * 1024 else { throw ValidationError("Setup pack is too large.") }
        var pack = try JSONDecoder().decode(SetupPack.self, from: data)
        pack=try RustCore.decode(Self.self,from:RustCore.policy(["op":"normalizeSetupPack","value":RustCore.encoded(pack)]))
        return pack
    }
}
public struct ValidationError: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
