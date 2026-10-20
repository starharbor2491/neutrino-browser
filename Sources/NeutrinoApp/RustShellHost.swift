// SPDX-License-Identifier: MPL-2.0
import AppKit
import AVFoundation
import Combine
import NeutrinoCore
import NeutrinoRust
import SwiftUI
@preconcurrency import WebKit

/// Swift is the macOS adapter: window/view ownership, engine lifecycle and system
/// services. All application chrome, interaction state and rendering live in Rust.
struct RustShellView: NSViewRepresentable {
    @ObservedObject var app: AppState
    var model: BrowserModel?
    var downloadCenter: DownloadCenter? = nil
    var previewStep: Int? = nil
    var openWindow: ((Bool) -> Void)?
    func makeCoordinator() -> RustShellCoordinator { RustShellCoordinator(app: app, model: model, downloadCenter: downloadCenter, previewStep: previewStep, openWindow: openWindow) }
    func makeNSView(context: Context) -> RustShellContainer { context.coordinator.container }
    func updateNSView(_ view: RustShellContainer, context: Context) { context.coordinator.scheduleSync() }
    static func dismantleNSView(_ view: RustShellContainer, coordinator: RustShellCoordinator) { coordinator.stop() }
}

private final class RustShellHandle {
    let value: UnsafeMutableRawPointer
    init() { value = neutrino_shell_new()! }
    deinit { neutrino_shell_free(value) }
    func dispatch(_ request: [String: Any]) -> [String: Any] {
        var bounded = request
        var payload = try? JSONSerialization.data(withJSONObject: bounded)
        if let data = payload, data.count > 8_388_608,
           var snapshot = bounded["snapshot"] as? [String:Any] {
            // Captured backgrounds are optional decoration. Drop them before
            // allowing pictures to prevent interaction with actual data.
            snapshot["pageBackdrops"] = [:]; bounded["snapshot"] = snapshot
            payload = try? JSONSerialization.data(withJSONObject: bounded)
        }
        guard let data = payload, data.count <= 8_388_608,
              let input = String(data: data, encoding: .utf8),
              let result = input.withCString({ neutrino_shell_dispatch(value, $0) }) else { return ["error": "The interface request could not be encoded."] }
        defer { neutrino_string_free(result) }
        return (try? JSONSerialization.jsonObject(with: Data(String(cString: result).utf8))) as? [String: Any] ?? ["error": "The interface returned an invalid response."]
    }
}

@MainActor
final class RustShellContainer: NSView {
    let chrome: WKWebView
    var mounted: [UUID: EngineViewContainer] = [:]
    private var dragRegions: [WindowDragRegion] = []
    override var isFlipped: Bool { true }
    init(chrome: WKWebView) {
        self.chrome = chrome
        super.init(frame: .zero)
        wantsLayer = true
        chrome.translatesAutoresizingMaskIntoConstraints = true
        chrome.autoresizingMask = [.width, .height]
        addSubview(chrome)
        identifier = NSUserInterfaceItemIdentifier("neutrino.browserLayout")
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden
        window?.styleMask.insert(.fullSizeContentView)
    }
    func setDragRegions(_ rectangles: [NSRect]) {
        dragRegions.forEach { $0.removeFromSuperview() }; dragRegions = rectangles.map { rectangle in
            let view = WindowDragRegion(frame: rectangle.intersection(bounds)); addSubview(view); return view
        }
    }
    override func layout() { super.layout(); chrome.frame = bounds }
    func hidePages() { for page in mounted.values { page.isHidden = true } }
    func retainPages(_ ids: Set<UUID>) {
        for id in Array(mounted.keys) where !ids.contains(id) {
            if let view = mounted.removeValue(forKey: id) { view.unmount(); view.removeFromSuperview() }
        }
    }
    func nativeHit(_ point: NSPoint) -> Bool {
        mounted.values.contains { !$0.isHidden && $0.frame.contains(point) } || dragRegions.contains { $0.frame.contains(point) }
    }
    func unmount() { for page in mounted.values { page.unmount(); page.removeFromSuperview() }; mounted.removeAll() }
}

@MainActor private final class WindowDragRegion: NSView {
    override var isOpaque: Bool { false }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) }
        else { window?.performDrag(with: event) }
    }
}

@MainActor
private final class ShellAssets: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.scheme == "neutrino-ui", url.host == "shell",
              ["/index.html", "/shell.css", "/shell.js", "/neutrino.svg"].contains(url.path),
              let pointer = String(url.path.dropFirst()).withCString({ neutrino_shell_asset($0) }) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        defer { neutrino_string_free(pointer) }
        let data = Data(String(cString: pointer).utf8)
        let type = url.path.hasSuffix(".svg") ? "image/svg+xml" : url.path.hasSuffix(".css") ? "text/css" : url.path.hasSuffix(".js") ? "text/javascript" : "text/html"
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

@MainActor
final class RustShellCoordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    let app: AppState
    let model: BrowserModel?
    let downloadCenter: DownloadCenter?
    let container: RustShellContainer
    private let handle = RustShellHandle()
    private let assets = ShellAssets()
    private var subscriptions = Set<AnyCancellable>()
    private var downloadObservations = Set<AnyCancellable>()
    private weak var observedDownloads: DownloadCenter?
    private var observedDownloadIDs: [UUID] = []
    private var selectedNoteID: UUID?
    private var sourceRestoreTask: Task<Void,Never>?
    private var allNotes = false
    private var notesQuery = ""
    private var noteSearchQuery = ""
    private var noteSearchCache: [UUID: (text: String, quote: String, matches: Bool)] = [:]
    private var librarySection = "bookmarks"
    private var selectedSettingsID = ""
    private var libraryPage = 0
    private var engineObservations = Set<AnyCancellable>()
    private var observedEngines = Set<ObjectIdentifier>()
    private var responseDocument: String?
    private var pendingSync: Task<Void, Never>?
    private var renderGeneration = 0
    private var showingOverlay = true
    private var pendingPageFocus: UUID?
    private var accountTask: Task<Void,Never>?
    private var backdropTask: Task<Void,Never>?
    private var pageBackdrops: [String:String] = [:]
    private var backdropRevisions: [UUID:UUID] = [:]
    private var nonModalMenuRect: NSRect?
    private let editingOwner = UUID()
    private var editingEngines: [BrowserEngineTab] = []
    private var editingInputMonitor: Any?
    private var credentialMetadata: [[String: String]] = []
    private var ready = false
    private var appliedFocusToken: Int?
    private let resourceWorker = ResourceWorker()
    private var resourceGeneration: UUID?
    private var resourcesOpen = false
    private var stopped = false
    private var projectedProfileID: UUID?
    private var downloadScreenOpened = false
    private var imported = false
    private var importedFrom = ""
    private var defaultStatus = ""
    private var assistantResponse = ""
    /// The article's images for Reader, fetched and downsized: [{src (data URL), alt, anchor}].
    private var readerImages: [[String: String]] = []
    private var readerVoice: ReaderVoice?
    private var boardsVisible = false
    private var assistantTask: Task<Void, Never>?
    private var assistantGeneration = UUID()
    private var previewStep: Int?
    private let isPreview: Bool
    private var lastSheet: BrowserSheet?
    private var lastPanel: BrowserPanel?
    private let openWindow: ((Bool) -> Void)?
    private lazy var features = BrowserFeatures(app: app, model: model, window: { [weak self] in self?.container.window }, refresh: { [weak self] in self?.scheduleSync() })
    /// Keyboard shortcuts from the interface: binding to action.
    private var shortcutMap: [String: String] = [:]
    private var findOpen = false
    /// Standard shortcuts the menu bar already performs.
    private static let menuShortcuts: [String: String] = ["new-tab": "cmd+t", "new-window": "cmd+n", "private-window": "shift+cmd+n", "reopen-tab": "shift+cmd+t",
        "close-tab": "cmd+w", "bookmark": "cmd+d", "settings": "cmd+,", "palette": "cmd+k", "find": "cmd+f"]
    init(app: AppState, model: BrowserModel?, downloadCenter: DownloadCenter?, previewStep: Int?, openWindow: ((Bool) -> Void)?) {
        self.app = app; self.model = model; self.downloadCenter = downloadCenter; self.previewStep = previewStep; self.isPreview = previewStep != nil; self.openWindow = openWindow
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(assets, forURLScheme: "neutrino-ui")
        let chrome = WKWebView(frame: .zero, configuration: configuration)
        container = RustShellContainer(chrome: chrome)
        super.init()
        chrome.navigationDelegate = self
        editingInputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let mouseDown = event.type == .leftMouseDown || event.type == .rightMouseDown
            var windowIDs: [ObjectIdentifier] = []
            var eventWindow = event.window
            while let window = eventWindow {
                windowIDs.append(ObjectIdentifier(window))
                eventWindow = window.parent
            }
            let ownedWindowIDs = windowIDs
            let screenPoint = mouseDown ? event.window?.convertPoint(toScreen:event.locationInWindow) : nil
            let originWindowID = event.window.map(ObjectIdentifier.init)
            let escape = event.type == .keyDown && event.keyCode == 53
            let closeTab = event.type == .keyDown && event.charactersIgnoringModifiers?.lowercased() == "w" &&
                event.modifierFlags.intersection([.command,.shift,.option,.control]) == .command
            let binding = event.type == .keyDown ? RustShellCoordinator.binding(for: event) : nil
            let typed = event.type == .keyDown && event.modifierFlags.intersection([.command, .control]).isEmpty && !(event.characters ?? "").isEmpty
            let blocked = MainActor.assumeIsolated {
                guard let self, !self.stopped,
                      let window = self.container.window, ownedWindowIDs.contains(ObjectIdentifier(window)) else { return false }
                if mouseDown {
                    if let screenPoint {
                        let point=self.container.convert(window.convertPoint(fromScreen:screenPoint),from:nil)
                        if self.container.nativeHit(point) { self.sourceRestoreTask?.cancel() }
                    }
                    if let menu = self.nonModalMenuRect, let screenPoint {
                        let point = self.container.convert(window.convertPoint(fromScreen:screenPoint),from:nil)
                        if !menu.contains(point), self.container.nativeHit(point) { self.sendAction(["op":"escape"]) }
                    }
                    return false
                }
                if event.type == .keyDown,originWindowID != ObjectIdentifier(window) { self.sourceRestoreTask?.cancel() }
                if escape, self.ready, self.model?.focusMode == true, window.attachedSheet==nil, NSApp.modalWindow==nil {
                    self.sendAction(["op":"escape"]); return true
                }
                guard originWindowID==ObjectIdentifier(window) else { return false }
                if !self.editingEngines.isEmpty,
                   let responder = self.container.window?.firstResponder as? NSView,
                   self.editingEngines.contains(where: { responder === $0.nativeView || responder.isDescendant(of: $0.nativeView) }) {
                    self.container.window?.makeFirstResponder(self.container.chrome)
                    return true
                }
                // Cocoa's default Command-W closes the whole window before WK
                // receives a DOM key event. Own tab closing on the browser window,
                // including the address palette and the empty new-tab surface.
                if closeTab, self.ready, let model = self.model, !model.isClosed, self.shortcutMap.isEmpty || self.shortcutMap["cmd+w"] == "close-tab" {
                    self.sendAction(["op":"closeCurrent"])
                    return true
                }
                if let binding, self.ready, let model = self.model, !model.isClosed, NSApp.modalWindow == nil, window.attachedSheet == nil,
                   let request = self.shortcutRequest(binding) {
                    if request["op"] as? String != "noop" { self.sendAction(request) }
                    return true
                }
                if typed, self.app.feature("sounds"), self.app.library.preferences.keyboardSounds == true {
                    self.container.chrome.evaluateJavaScript("window.neutrinoSound&&window.neutrinoSound('key')", completionHandler: nil)
                }
                return false
            }
            return blocked ? nil : event
        }
        chrome.setValue(false, forKey: "drawsBackground")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "neutrino")
        resourceWorker.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &subscriptions)
        app.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &subscriptions)
        app.$finalQuitDataFrozen.sink { [weak self] frozen in
            // Release AppKit page ownership immediately, including while the
            // interface renderer is reloading. A refused quit can remount it.
            if frozen { self?.container.unmount() }
        }.store(in: &subscriptions)
        model?.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &subscriptions)
        DistributionManager.shared.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &subscriptions)
        ChatGPTAccount.shared.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &subscriptions)
        downloadCenter?.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &subscriptions)
        if let model {
            model.downloads.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &subscriptions)
            NotificationCenter.default.publisher(for: .neutrinoFocusAddress).sink { [weak self] notification in
                guard notification.object as? UUID == model.session.id else { return }
                self?.sendAction(["op": "focus-address"])
                self?.container.window?.makeKey()
                self?.container.window?.makeFirstResponder(self?.container.chrome)
            }.store(in: &subscriptions)
            NotificationCenter.default.publisher(for: .neutrinoFind).sink { [weak self] notification in
                guard notification.object as? UUID == model.session.id else { return }
                self?.sendAction(["op": "find-open"])
            }.store(in: &subscriptions)
            NotificationCenter.default.publisher(for: .neutrinoOpenBrowserWindow).sink { [weak self] notification in
                guard notification.object as? UUID == model.session.id else { return }
                self?.openWindow?(notification.userInfo?["private"] as? Bool == true)
            }.store(in: &subscriptions)
        }
        model?.shellAction = { [weak self] request in self?.sendAction(request) }
        model?.stopInterface = { [weak self] in await self?.stopAndWait() }
        model?.features = features
        features.start()
        chrome.load(URLRequest(url: URL(string: "neutrino-ui://shell/index.html")!))
    }
    private func stopAndWait() async {
        let assistant=assistantTask, backdrop=backdropTask, account=accountTask, source=sourceRestoreTask
        stop()
        await assistant?.value
        await backdrop?.value
        await account?.value
        await source?.value
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        sourceRestoreTask?.cancel();sourceRestoreTask=nil
        if accountTask != nil {accountTask?.cancel();ChatGPTAccount.shared.cancelSignIn()}
        backdropTask?.cancel();backdropTask=nil;pageBackdrops=[:];backdropRevisions=[:]
        resourceWorker.stop()
        features.stop()
        editingEngines.forEach { $0.setInterfaceEditing(false, owner: editingOwner) }; editingEngines.removeAll()
        if let editingInputMonitor { NSEvent.removeMonitor(editingInputMonitor) }; editingInputMonitor = nil
        pendingSync?.cancel(); assistantTask?.cancel(); model?.shellAction = nil; model?.stopInterface = nil; subscriptions.removeAll(); downloadObservations.removeAll(); engineObservations.removeAll(); observedEngines.removeAll()
        container.chrome.configuration.userContentController.removeScriptMessageHandler(forName: "neutrino", contentWorld: .page)
        container.chrome.navigationDelegate = nil
        container.unmount()
    }
    func scheduleSync() {
        guard !stopped, pendingSync == nil else { return }
        pendingSync = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }; self.pendingSync = nil
            guard self.ready, !self.stopped else { return }
            self.push(self.synchronize())
        }
    }
    /// A shortcut as "ctrl+alt+shift+cmd+key", named from the unmodified key.
    nonisolated static func binding(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let named: [UInt16: String] = [48: "tab", 53: "esc", 51: "delete", 117: "delete", 36: "enter", 76: "enter", 49: "space",
            126: "up", 125: "down", 123: "left", 124: "right", 122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
            98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]
        guard let key = named[event.keyCode] ?? event.characters(byApplyingModifiers: [])?.lowercased(), !key.isEmpty else { return nil }
        return [flags.contains(.control) ? "ctrl" : nil, flags.contains(.option) ? "alt" : nil, flags.contains(.shift) ? "shift" : nil,
                flags.contains(.command) ? "cmd" : nil, key].compactMap { $0 }.joined(separator: "+")
    }
    /// The interface request for a shortcut the menu bar does not already perform.
    private func shortcutRequest(_ binding: String) -> [String: Any]? {
        let parts = binding.split(separator: "+")
        if parts.count == 2, parts[0] == "cmd", let digit = Int(parts[1]), (1...9).contains(digit) { return ["op": "select-index", "value": digit] }
        if findOpen, binding == "cmd+g" || binding == "shift+cmd+g" { return ["op": "find-step", "value": binding.hasPrefix("shift") ? -1 : 1] }
        if binding == "shift+cmd+=" { return ["op": "run-action", "value": "zoom-in"] }
        guard let action = shortcutMap[binding] else {
            // A standard menu shortcut the person removed or gave to another action does nothing.
            return !shortcutMap.isEmpty && Self.menuShortcuts.values.contains(binding) ? ["op": "noop"] : nil
        }
        guard Self.menuShortcuts[action] != binding else { return nil }
        return ["op": "run-action", "value": action]
    }
    private func observeDownloads(_ center: DownloadCenter?) {
        let ids = center?.items.map(\.id) ?? []
        guard observedDownloads !== center || observedDownloadIDs != ids else { return }
        observedDownloads = center; observedDownloadIDs = ids; downloadObservations.removeAll()
        center?.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &downloadObservations)
        for item in center?.items ?? [] { item.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &downloadObservations) }
    }
    private func encoded<T: Encodable>(_ value: T) -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)) ?? NSNull() }
    private func matchesNoteContent(_ note: Note) -> Bool {
        guard !notesQuery.isEmpty else { return false }
        let quote = note.quotedText ?? ""
        if let cached = noteSearchCache[note.id], cached.text == note.text, cached.quote == quote { return cached.matches }
        let matches = RustCore.textContains(quote, query: notesQuery) || RustCore.textContains(note.text, query: notesQuery)
        noteSearchCache[note.id] = (note.text, quote, matches)
        return matches
    }
    private func synchronize() -> [String: Any] {
        if let model {
            // A pristine selection has no page surface. Detach its anchor even
            // while an overlay is open; the adapter retains its live browser
            // group and will remount when a navigated sibling is selected.
            let panels = (app.library.preferences.webPanels ?? []).filter { $0.profileID == model.session.profileID }.map(\.id)
            let retained = app.finalQuitDataFrozen ? Set<UUID>() : Set(model.session.tabs.filter { $0.url != nil }.map(\.id) + panels)
            container.retainPages(retained)
        }
        if let center = downloadCenter {
            // Auxiliary windows receive only their own download capability. They
            // must not inherit the default Profile when no BrowserModel exists.
            observeDownloads(center)
            let snapshot: [String: Any] = ["downloadsWindow":true,"completedOnboarding":true,
                "frozen":app.finalQuitDataFrozen,"private":true,
                "downloads":center.items.map(\.summary)]
            return stamped(handle.dispatch(["op":"sync","snapshot":snapshot]))
        }
        let update = DistributionManager.shared
        let profileID = model?.session.profileID ?? app.library.profiles[0].id
        if projectedProfileID != profileID {
            projectedProfileID = profileID; assistantGeneration = UUID(); assistantTask?.cancel(); assistantTask = nil
            assistantResponse = ""; readerImages = []; readerVoice?.stop(); credentialMetadata = []; selectedNoteID = nil; libraryPage = 0; notesQuery=""; allNotes=false
            noteSearchCache.removeAll()
        }
        if noteSearchQuery != notesQuery { noteSearchQuery = notesQuery; noteSearchCache.removeAll() }
        let searchableNoteIDs = Set(app.library.notes.filter { $0.profileID == profileID }.map(\.id))
        for id in Array(noteSearchCache.keys) where !searchableNoteIDs.contains(id) { noteSearchCache.removeValue(forKey: id) }
        let space = model?.space
        observeDownloads(downloadCenter ?? model?.downloads)
        let regular = model?.isPrivate != true
        let bookmarkQuery = features.bookmarkQuery.lowercased(), historyQuery = features.historyQuery.lowercased()
        let allBookmarks = regular ? app.library.bookmarks.filter { $0.profileID == profileID } : []
        let bookmarks = bookmarkQuery.isEmpty ? allBookmarks : allBookmarks.filter { $0.title.lowercased().contains(bookmarkQuery) || $0.url.absoluteString.lowercased().contains(bookmarkQuery) || ($0.folder ?? "").lowercased().contains(bookmarkQuery) }
        let noteIndex:[[String:Any]]=regular ? app.library.notes.map { note in
            ["id":note.id.uuidString,"profileID":note.profileID.uuidString,"spaceID":note.spaceID?.uuidString ?? "", "title":String(note.title.prefix(100)),
             "sourceURL":note.sourceURL?.absoluteString ?? "","sourceTitle":note.sourceTitle ?? "","modifiedAt":note.modifiedAt.timeIntervalSinceReferenceDate,
             "spaceName":app.library.spaces?.first(where:{$0.id==note.spaceID})?.name ?? "",
             "contentMatch":note.profileID == profileID && (allNotes || note.spaceID == nil || note.spaceID == model?.session.spaceID) && matchesNoteContent(note)]
        } : []
        let noteIDs=(try? RustCore.request(["op":"projectNotes","value":noteIndex,"profileID":profileID.uuidString,"spaceID":model?.session.spaceID?.uuidString ?? "","all":allNotes,"query":notesQuery]) as? [String]) ?? []
        let records=app.library.notes.reduce(into:[String:Note]()){$0[$1.id.uuidString]=$1}
        let notes=noteIDs.compactMap{records[$0]}
        let history = regular ? Array(app.library.history.filter { $0.profileID == profileID && (historyQuery.isEmpty || $0.title.lowercased().contains(historyQuery) || $0.url.absoluteString.lowercased().contains(historyQuery)) }.reversed()) : []
        let count = librarySection == "notes" ? notes.count : librarySection == "history" ? history.count : bookmarks.count
        libraryPage = min(libraryPage, max(0, (count - 1) / 40))
        let offset = libraryPage * 40
        let selectedNote = notes.first { $0.id == selectedNoteID } ?? notes.first
        func noteContext(_ note:Note, content:Bool=false) -> [String:Any] {
            let quote = note.quotedText ?? ""
            var value:[String:Any]=["id":note.id.uuidString,"title":String(note.title.prefix(100)),"sourceURL":note.sourceURL?.absoluteString ?? "",
             "sourceTitle":note.sourceTitle ?? "","spaceName":app.library.spaces?.first(where:{$0.id==note.spaceID})?.name ?? "",
             "sourceTabID":note.sourceTabID?.uuidString ?? "",
             "excerpt":String((quote.isEmpty ? note.text : quote).prefix(240))]
            if content {value["text"]=String(note.text.prefix(200_000));value["quotedText"]=String(quote.prefix(16_000))}
            return value
        }
        var snapshot: [String: Any] = [
            "completedOnboarding": !isPreview && app.library.preferences.completedOnboarding,
            "smoke": model != nil && CommandLine.arguments.contains("--smoke-test"),
            "private": model?.isPrivate ?? false, "frozen": app.finalQuitDataFrozen,
            "saving": app.onboardingSaving, "spaceName": space?.name ?? "Everyday",
            "profileName": model?.profile.name ?? app.library.profiles[0].name,
            "preferences": encoded(app.library.preferences),
            "savedConfigurations": encoded(app.library.preferences.savedConfigurations),
            "configuration": encoded(model?.configuration ?? app.library.preferences.configuration),
            "profiles": encoded(app.library.profiles),
            "spaces": encoded((app.library.spaces ?? []).map { SpaceIdentity(id: $0.id, name: $0.name, profileID: $0.profileID, emoji: $0.emoji, gradient: $0.gradient) }),
            "folders": encoded(space?.folders ?? []), "archived": (space?.archivedTabs ?? []).prefix(200).map { ["id": $0.id.uuidString, "title": String($0.title.prefix(512)), "url": String(($0.url?.absoluteString ?? "").prefix(8192))] },
            "bookmarks": bookmarks.dropFirst(librarySection == "bookmarks" ? offset : 0).prefix(40).map { ["id": $0.id.uuidString, "title": String($0.title.prefix(512)), "url": String($0.url.absoluteString.prefix(8192)), "folder": $0.folder ?? ""] },
            "bookmarkIndex": allBookmarks.prefix(500).map { ["id": $0.id.uuidString, "title": String($0.title.prefix(512)), "url": String($0.url.absoluteString.prefix(8192)), "folder": $0.folder ?? ""] },
            "history": history.dropFirst(librarySection == "history" ? offset : 0).prefix(40).map { ["id": $0.id.uuidString, "title": String($0.title.prefix(512)), "url": String($0.url.absoluteString.prefix(8192)), "visitedAt": $0.visitedAt.timeIntervalSinceReferenceDate] as [String: Any] },
            "notes": notes.dropFirst(librarySection == "notes" ? offset : 0).prefix(40).map {noteContext($0)},
            "notesScope": allNotes ? "all" : "space", "notesQuery":notesQuery,
            "selectedNote": selectedNote.map {noteContext($0,content:true)} as Any? ?? NSNull(),
            "libraryPage": libraryPage, "libraryCount": count,
            "account": ["connected": ChatGPTAccount.shared.connected, "busy": ChatGPTAccount.shared.busy, "status": ChatGPTAccount.shared.status ?? "", "models": ChatGPTAccount.shared.models],
            "notice": app.notice ?? "", "defaultStatus": defaultStatus, "isDefaultBrowser": isDefaultBrowser, "imported": imported, "importedFrom": importedFrom, "zoom": model?.activeWebTab.zoom ?? 1,
            "blinkAvailable": ChromiumRuntime.shared.isInstalled(in: app.dataDirectory),
            "engineVersion": ChromiumRuntime.cefVersion.components(separatedBy:"chromium-").last ?? "unavailable",
            "assistantResponse": assistantResponse, "assistantBusy": assistantTask != nil,
            "updates": ["version": "Neutrino " + (update.current?.version ?? "development"), "automatic": update.automaticUpdates,
                        "message": update.message ?? "Updates are downloaded from GitHub. Your browsing data is kept.", "busy": update.busy, "pending": update.pending != nil,
                        "available": update.available.first?.release.version ?? "", "invalid": update.pendingRecordInvalid],
            "modules": moduleSnapshot(), "moduleCatalogs": app.communityCatalogNames,
            "menuItems": encoded(app.declarativeDefinition(.menu)?.menu ?? []),
            "svgIcons": app.declarativeDefinition(.icons)?.svgIcons ?? [:],
            "startWidgets": encoded(app.startWidgets),
            "resources": ["frame": encoded(resourceWorker.frame), "failure": resourceWorker.failure ?? ""],
        ]
        if let model, !model.isClosed {
            var projectedSession = model.session
            for i in projectedSession.tabs.indices {
                projectedSession.tabs[i].chromiumPages = nil
                projectedSession.tabs[i].title = String(projectedSession.tabs[i].title.prefix(512))
                if let url = projectedSession.tabs[i].url, url.absoluteString.utf8.count > 8192 { projectedSession.tabs[i].url = nil }
                if (projectedSession.tabs[i].faviconDataURL?.utf8.count ?? 0) > 12_000 { projectedSession.tabs[i].faviconDataURL = nil }
            }
            snapshot["session"] = encoded(projectedSession)
            snapshot["chromePages"] = model.chromePageSnapshots
            snapshot["chromePageCounts"] = model.chromePageCounts
            snapshot["pageBackdrops"] = Dictionary(uniqueKeysWithValues:model.visibleEngineTabs.compactMap {entry -> (String,String)? in
                guard backdropRevisions[entry.id]==entry.page.navigationRevision,let image=pageBackdrops[entry.id.uuidString] else{return nil}
                return (entry.id.uuidString,image)
            })
            snapshot["focusMode"] = model.focusMode
            snapshot["focusHidden"] = Array(model.focusHiddenComponents).sorted()
            let tab = model.activeWebTab
            snapshot["loading"] = tab.loading
            snapshot["canGoBack"] = tab.canGoBack
            snapshot["canGoForward"] = tab.canGoForward
            let visible = model.visibleEngineTabs
            snapshot["pageErrors"] = Dictionary(uniqueKeysWithValues: visible.compactMap { id, page in page.errorMessage.map { (id.uuidString, $0) } })
            if let error = tab.errorMessage { snapshot["pageError"] = error }
            snapshot["downloads"] = model.downloads.items.map(\.summary)
            // Only account identity is projected. Password values never enter the UI snapshot.
            snapshot["credentials"] = credentialMetadata
            let engines = visible.map(\.page)
            let identities = Set(engines.map(ObjectIdentifier.init))
            if observedEngines != identities {
                observedEngines = identities; engineObservations.removeAll()
                for engine in engines { engine.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in:&engineObservations) }
            }
            let document = model.session.selectedTabID.uuidString + ":" + tab.navigationRevision.uuidString
            if let responseDocument, responseDocument != document { assistantResponse = ""; readerImages = []; readerVoice?.stop(); self.responseDocument = nil }
            snapshot["assistantResponse"] = assistantResponse
            snapshot["readerImages"] = readerImages
            if boardsVisible, !model.isPrivate { snapshot["boardImages"] = features.boardImages(profileID: model.session.profileID) }
            snapshot["readerSpeaking"] = readerVoice?.speaking == true
            features.snapshot(into: &snapshot, model: model)

        }
        if let center = downloadCenter {
            snapshot["downloads"] = center.items.map(\.summary)
        }
        if features.credentialsChanged { features.credentialsChanged = false; refreshCredentialMetadata(profileID: profileID) }
        var result = handle.dispatch(["op": "sync", "snapshot": snapshot])
        if let panel = features.pendingPanel { features.pendingPanel = nil; result = handle.dispatch(["op": "panel", "value": panel]) }
        if let id = result["moduleSettingsID"] as? String, id != selectedSettingsID {
            selectedSettingsID = id; return synchronize()
        }
        if let section=result["librarySection"] as? String,["bookmarks","history","downloads","notes","archive"].contains(section),section != librarySection {
            librarySection=section;libraryPage=0;return synchronize()
        }
        // Board pictures are sent only while a board is showing.
        let showingBoards = result["librarySection"] as? String == "boards"
        if showingBoards != boardsVisible { boardsVisible = showingBoards; if showingBoards { return synchronize() } }
        if downloadCenter != nil && !downloadScreenOpened { downloadScreenOpened = true; result = handle.dispatch(["op": "screen", "value": "library", "section": "downloads"]) }
        if let step = previewStep { result = handle.dispatch(["op": "setup-step", "value": step]); previewStep = nil }
        if let sheet = model?.sheet, sheet != lastSheet {
            lastSheet = sheet
            let screen: String = switch sheet { case .customize: "editor"; case .modules: "modules"; case .extensions: "extensions"; case .assistant: "assistant"; case .recovery: "recovery"; default: "settings" }
            result = handle.dispatch(["op": "screen", "value": screen, "section": sheet == .engines ? "updates" : "general"])
        }
        if model?.sheet == nil { lastSheet = nil }
        if let panel = model?.panel, panel != lastPanel { lastPanel = panel; result = handle.dispatch(["op": "screen", "value": "library", "section": panel.rawValue]) }
        if model?.panel == nil { lastPanel = nil }
        if result["overlay"] as? Bool == true { container.hidePages() }
        return stamped(result)
    }
    private func stamped(_ response: [String: Any]) -> [String: Any] {
        let needsResources = response["resourcesVisible"] as? Bool == true && model != nil && !app.terminating && !app.finalQuitDataFrozen
        if needsResources && (!resourcesOpen || resourceGeneration != app.resourceWorkerGeneration) {
            resourcesOpen = true; resourceGeneration = app.resourceWorkerGeneration
            do { let package = try app.resourceWorkerPackage(); try resourceWorker.start(executable: package.url, moduleID: package.id) }
            catch { resourceWorker.showFailure(error) }
        } else if !needsResources && resourcesOpen {
            resourcesOpen = false; resourceGeneration = nil; resourceWorker.stop()
        }
        if let list = response["shortcuts"] as? [[String]] {
            shortcutMap = Dictionary(list.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }, uniquingKeysWith: { _, last in last })
        }
        findOpen = response["findOpen"] as? Bool == true
        // Read aloud belongs to the Reader: leaving it stops the speech.
        if response["screen"] as? String != "reader", readerVoice?.speaking == true { readerVoice?.stop() }
        features.sampleResources = response["performanceVisible"] as? Bool == true
        renderGeneration += 1
        var result = response; result["generation"] = renderGeneration
        showingOverlay = response["overlay"] as? Bool ?? true
        let editing = response["editing"] as? Bool == true
        let next = editing ? (model?.visibleEngineTabs.map(\.page) ?? []) : []
        let entering = editingEngines.isEmpty && !next.isEmpty
        for engine in editingEngines where !next.contains(where: { $0 === engine }) { engine.setInterfaceEditing(false, owner: editingOwner) }
        for engine in next where !editingEngines.contains(where: { $0 === engine }) { engine.setInterfaceEditing(true, owner: editingOwner) }
        editingEngines = next
        if entering { container.window?.makeKey(); container.window?.makeFirstResponder(container.chrome) }
        if response["focus"] as? String == "address-input" || response["focus"] as? String == "command-input" {pendingPageFocus=nil}
        if let token = response["focusToken"] as? Int, token != appliedFocusToken,
           let focus = response["focus"] as? String, !focus.isEmpty {
            appliedFocusToken = token
            container.window?.makeKey(); container.window?.makeFirstResponder(container.chrome)
        }
        if showingOverlay { container.hidePages() }
        return result
    }
    private func moduleSnapshot() -> [[String:Any]] {
        let catalogIDs = Set(app.catalog.map(\.id))
        let projection = app.modulePresentation
        let installedByID = Dictionary(uniqueKeysWithValues:app.installedModules.map {($0.id,$0)})
        let catalogNames = Dictionary(uniqueKeysWithValues:app.catalog.map {($0.id,$0.name)})
        let providers = Dictionary(app.installedModules.filter { $0.enabled }.map {($0.manifest.capability,$0)}, uniquingKeysWith:{first,_ in first})
        let manifests = app.catalog + app.installedModules.filter { !catalogIDs.contains($0.id) }.map(\.manifest)
        return manifests.map { manifest in
            let installed = installedByID[manifest.id]
            let current = installed?.manifest ?? manifest
            let provider = providers[current.capability].flatMap { $0.id == current.id ? nil : $0 }
            let values = projection.settings[current.id] ?? [:]
            let settings: [[String:Any]] = (current.id == selectedSettingsID ? current.settings ?? [] : []).map { setting in
                ["id":setting.id,"title":setting.title,"kind":setting.kind.rawValue,
                 "choices":setting.choices ?? [],"value":encoded(values[setting.id] ?? setting.defaultValue)]
            }
            return ["id":current.id,"name":current.name,"description":current.summary,
                    "version":current.version,"availableVersion":manifest.version,"publisher":current.publisher,
                    "capability":current.capability.rawValue,"permission":current.capability.permission ?? "",
                    "installed":installed != nil,"enabled":installed?.enabled == true,
                    "available":catalogIDs.contains(current.id),"bundled":app.bundledModuleIDs.contains(current.id),
                    "updateAvailable":installed != nil && manifest.version > current.version,
                    "replacesProvider":current.capability.isExclusive && provider != nil,
                    "providerName":current.capability.isExclusive ? provider?.manifest.name ?? "" : "",
                    "dependencies":current.dependencies.map { catalogNames[$0] ?? $0 },
                    "error":projection.errors[current.id] ?? projection.errors["*"] ?? "",
                    "settings":settings] as [String:Any]
        }
    }
    private struct SpaceIdentity: Encodable { let id: UUID; let name: String; let profileID: UUID; let emoji: String?; let gradient: [String]? }
    private func push(_ response: [String: Any], interactive: Bool = false) {
        var result = response; result["passive"] = !interactive
        guard ready, !stopped, let data = try? JSONSerialization.data(withJSONObject: result), let json = String(data: data, encoding: .utf8) else { return }
        if result["overlay"] as? Bool == true { container.hidePages() }
        container.chrome.evaluateJavaScript("window.neutrino.receive(\(json))", completionHandler: nil)
    }
    private func editorResult(action:String,success:Bool,message:String) {
        let result=handle.dispatch(["op":"editor-result","action":action,"success":success,"message":message])
        for command in result["commands"] as? [[String:Any]] ?? [] {perform(command)}
    }
    private func dispatchAction(_ request: [String:Any]) -> [String:Any] {
        let result=handle.dispatch(request)
        var needsSync = false
        if let id = result["moduleSettingsID"] as? String, id != selectedSettingsID { selectedSettingsID = id; needsSync = true }
        if let commands=result["commands"] as? [[String:Any]],!commands.isEmpty {
            for command in commands {perform(command)}
            needsSync = true
        }
        return needsSync ? synchronize() : stamped(result)
    }
    private func prepareAction(_ request: [String:Any],completion:@escaping @MainActor ([String:Any])->Void) {
        if ["escape","focus-address","screen","selectTab","switchSpace"].contains(request["op"] as? String ?? "") {backdropTask?.cancel()}
        guard ["newTab","palette","menu"].contains(request["op"] as? String ?? ""),
              !showingOverlay,let model,model.hasPage else{completion(dispatchAction(request));return}
        backdropTask?.cancel()
        let profile=model.session.profileID,selected=model.session.selectedTabID
        let entries=model.visibleEngineTabs
        backdropTask=Task { @MainActor in
            var images=[String:String](),revisions=[UUID:UUID]()
            for entry in entries {
                let revision=entry.page.navigationRevision
                if let png=try? await entry.page.capturePNG(),png.count<=1_500_000,
                   entry.page.navigationRevision==revision {
                    images[entry.id.uuidString]="data:image/png;base64,"+png.base64EncodedString();revisions[entry.id]=revision
                }
                if Task.isCancelled{break}
            }
            guard !stopped,!Task.isCancelled,!model.isClosed,model.session.profileID==profile,model.session.selectedTabID==selected else{return}
            pageBackdrops=images;backdropRevisions=revisions
            push(synchronize())
        }
        // Opening chrome cannot wait on a renderer. The captured background is
        // decorative and may arrive after the command field already has focus.
        completion(dispatchAction(request))
    }
    private func sendAction(_ request: [String:Any]) {
        prepareAction(request){[weak self] result in self?.push(result,interactive:true)}
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard !stopped, message.webView === container.chrome, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.scheme == "neutrino-ui", message.frameInfo.request.url?.host == "shell",
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            replyHandler(nil, "Only the bundled Neutrino interface can invoke platform services."); return
        }
        switch kind {
        case "ready": ready = true; replyHandler(synchronize(), nil)
        case "geometry": updateGeometry(body); replyHandler([:], nil)
        case "zoom": container.window?.performZoom(nil); replyHandler([:], nil)
        case "action":
            guard let request = body["request"] as? [String: Any] else { replyHandler(nil, "Invalid action"); return }
            if downloadCenter != nil && request["op"] as? String == "escape" { container.window?.performClose(nil); replyHandler([:], nil); return }
            if (request["op"] as? String == "section" && request["value"] as? String == "passwords") || (request["op"] as? String == "screen" && request["section"] as? String == "passwords") {
                let profileID = model?.session.profileID ?? app.library.profiles[0].id
                refreshCredentialMetadata(profileID: profileID)
                _ = synchronize()
            }
            if request["op"] as? String == "escape" || request["op"] as? String == "screen" {
                model?.sheet = nil; model?.panel = nil; lastSheet = nil; lastPanel = nil
            }
            prepareAction(request){result in replyHandler(result,nil)}
        default: replyHandler(nil, "Unknown platform request")
        }
    }
    private func updateGeometry(_ body: [String: Any]) {
        guard ready, body["generation"] as? Int == renderGeneration else { return }
        if let r = body["menuRect"] as? [String:Double],
           let x=r["x"], let y=r["y"], let width=r["width"], let height=r["height"],
           [x,y,width,height].allSatisfy(\.isFinite), width>0,height>0,width<=container.bounds.width,height<=container.bounds.height {
            nonModalMenuRect = NSRect(x:x,y:y,width:width,height:height)
        } else { nonModalMenuRect = nil }
        if let rectangles = body["dragRegions"] as? [[String: Double]], rectangles.count <= 10 {
            container.setDragRegions(rectangles.compactMap { r in
                guard let x=r["x"], let y=r["y"], let width=r["width"], let height=r["height"], [x,y,width,height].allSatisfy(\.isFinite), width>0, height>0, height<=48 else { return nil }
                return NSRect(x:x,y:y,width:width,height:height)
            })
        }
        guard !app.finalQuitDataFrozen, !showingOverlay, let model, !model.isClosed, body["overlay"] as? Bool == false,
              let pages = body["pages"] as? [[String: Any]], pages.count <= 3 else { container.hidePages(); return }
        // A sidebar the interface draws over the pages, which leave that part uncovered.
        var uncovered = NSRect.zero
        if let r = body["uncovered"] as? [String: Double], let x = r["x"], let y = r["y"], let width = r["width"], let height = r["height"],
           [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 {
            uncovered = NSRect(x: x, y: y, width: width, height: height).intersection(container.bounds)
        }
        var visible = Set<UUID>()
        let allowed = model.session.split.map { Set([$0.first, $0.second]) } ?? Set([model.session.selectedTabID])
        let webPanels = (app.library.preferences.webPanels ?? []).filter { $0.profileID == model.session.profileID }
        for page in pages {
            guard let raw = page["id"] as? String, let id = UUID(uuidString: raw) else { continue }
            let panel = webPanels.first { $0.id == id }
            guard panel != nil || (allowed.contains(id) && model.session.tabs.contains(where: { $0.id == id && $0.url != nil })),
                  let x = page["x"] as? Double, let y = page["y"] as? Double,
                  let width = page["width"] as? Double, let height = page["height"] as? Double,
                  [x, y, width, height].allSatisfy(\.isFinite), width >= 1, height >= 1 else { continue }
            let rect = NSRect(x: x, y: y, width: width, height: height).intersection(container.bounds)
            guard !rect.isEmpty else { continue }
            let tab = panel.map { model.panelTab($0) } ?? model.webTab(id)
            let view = container.mounted[id] ?? EngineViewContainer(page: tab.nativeView)
            if view.superview !== container { container.addSubview(view) }
            view.mount(tab.nativeView); view.frame = rect; view.isHidden = false
            view.uncovered = uncovered.isEmpty ? .zero : view.convert(uncovered, from: container)
            view.isPreviewing = body["editing"] as? Bool == true
            view.identifier = NSUserInterfaceItemIdentifier("neutrino.page")
            view.wantsLayer = true; view.layer?.cornerRadius = min(34,max(0,(page["radius"] as? Double) ?? model.configuration.theme.cornerRadius)); view.layer?.cornerCurve = .continuous; view.layer?.masksToBounds = true
            container.mounted[id] = view; visible.insert(id)
            if pendingPageFocus==id,model.session.selectedTabID==id,NSApp.modalWindow==nil,container.window?.attachedSheet==nil {
                pendingPageFocus=nil;tab.focus()
            }
        }
        for (id, view) in container.mounted where !visible.contains(id) { view.isHidden = true }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !stopped, webView === container.chrome else { return }
        ready = false; container.hidePages()
        webView.load(URLRequest(url:URL(string:"neutrino-ui://shell/index.html")!))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.scheme == "neutrino-ui" && url?.host == "shell" && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
    }
    private func perform(_ command: [String: Any]) {
        guard !app.finalQuitDataFrozen, let operation = command["op"] as? String else { return }
        if downloadCenter != nil && !["downloadCancel","downloadPause","downloadResume","downloadReveal","downloadOpen"].contains(operation) { return }
        if ["navigate","newTab","selectTab","selectChromePage","closeChromePage","closeTab","duplicateTab",
            "reopenTab","back","forward","reload","stop","switchSpace","switchProfile","moveTabToSpace",
            "useWebKit","openNoteSource"].contains(operation) { sourceRestoreTask?.cancel() }
        let id = (command["id"] as? String).flatMap(UUID.init(uuidString:))
        let profileID = model?.session.profileID ?? app.library.profiles[0].id
        switch operation {
        case "navigate":
            if let value = command["url"] as? String { model?.navigate(value);pendingPageFocus=model?.session.selectedTabID }
        case "clearNotice": app.notice = nil
        case "uninstall": AppUninstaller.request(app)
        case "newTab":
            let parent=(command["parentID"] as? String).flatMap(UUID.init(uuidString:))
            // Without an address this is a blank tab showing the start page; the shell focuses its address field.
            guard let value=command["url"] as? String else { model?.newTab(parentID:parent); return }
            guard let url=URL(string:value), AddressResolver.isWebURL(url) else { return }
            model?.newTab(url:url, parentID:parent)
            pendingPageFocus=model?.session.selectedTabID
        case "selectTab": if let id { model?.selectTab(id) }
        case "selectChromePage", "closeChromePage":
            guard let id, let model, model.session.tabs.contains(where:{$0.id==id}), let pageID = command["page"] as? Int else { return }
            model.selectTab(id)
            if operation == "closeChromePage", model.activeWebTab.hasActiveDownloads {
                let alert = NSAlert(); alert.messageText = "Close this page while downloads are running?"
                alert.informativeText = "This tab group has active downloads. Closing a page with an active transfer cancels that transfer."
                alert.addButton(withTitle:"Keep page open"); alert.addButton(withTitle:"Close page")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
            }
            (model.activeWebTab as? ChromiumTab)?.selectInterfacePage(pageID,close:operation=="closeChromePage")
            pendingPageFocus = id
        case "closeTab": if let id { model?.requestCloseTab(id) }
        case "duplicateTab":
            if let model, let tab = model.session.tabs.first(where: { $0.id == id }) { model.newTab(url: tab.url, engine: tab.engineID) }
        case "pinTab": if let id { model?.pinTab(id) }
        case "toggleBranch": if let id { model?.toggleBranch(id) }
        case "reopenTab": model?.reopenClosedTab()
        case "back": model?.activeWebTab.goBack()
        case "forward": model?.activeWebTab.goForward()
        case "reload": model?.activeWebTab.reload()
        case "stop": model?.activeWebTab.stop()
        case "bookmark": model?.toggleBookmark()
        case "addBookmark":
            let folder = (command["folder"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
            guard let model, !model.isPrivate, let value = command["url"] as? String, let url = URL(string: value), AddressResolver.isWebURL(url),
                  !app.library.bookmarks.contains(where: { $0.url == url && $0.profileID == profileID && $0.folder == folder }) else { return }
            app.library.bookmarks.insert(Bookmark(profileID: profileID, title: String(((command["title"] as? String) ?? url.host ?? "Website").prefix(512)), url: url, folder: folder), at: 0)
            app.notice = folder.map { "Saved to \($0)." } ?? "Bookmark saved."
        case "home": model?.showStartPage()
        case "setZoom": if let value = command["value"] as? Double, value.isFinite { model?.activeWebTab.setZoom(value); model?.rememberZoom(value) }
        case "shieldsSite":
            guard let host = command["host"] as? String, !host.isEmpty, host.count <= 253, let down = command["down"] as? Bool else { return }
            var lowered = app.library.preferences.shieldsDown ?? []
            lowered.removeAll { $0 == host }
            if down { lowered.append(host) }
            app.library.preferences.shieldsDown = Array(lowered.suffix(500))
            for window in app.windows.values { window.model?.updateBlockingPolicy() }
        case "importBrowser":
            if let source = command["value"] as? String, app.importBrowserData(from: source, profileID: profileID) { imported = true; importedFrom = source }
        case "split": model?.beginSplit(.sideBySide)
        case "splitWith":
            if let model, let id, id != model.session.selectedTabID,
               model.session.tabs.contains(where:{$0.id==id && $0.url != nil}) {
                model.session.split=TabSplit(first:model.session.selectedTabID,second:id)
                model.session.splitSuppressed=nil
                var c=model.configuration;c.layout.split = .sideBySide
                app.applyConfiguration(c,to:model.session.spaceID)
            }
        case "unsplit": model?.endSplit()
        case "switchSpace": if let id, let model, app.library.spaces?.contains(where: { $0.id==id && $0.profileID==model.session.profileID })==true { model.switchSpace(id) }
        case "switchProfile": if let id { model?.switchProfile(id) }
        case "replaceTabs":
            guard let model, let source = command["tabs"], let data = try? JSONSerialization.data(withJSONObject: source),
                  let tabs = try? JSONDecoder().decode([BrowserTab].self, from: data),
                  tabs.count == model.session.tabs.count, Set(tabs.map(\.id)) == Set(model.session.tabs.map(\.id)) else { return }
            // Rust may change organization only. Engine URLs, titles and session pages
            // remain owned by the native document callbacks, including in-flight loads.
            let order = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($0.element.id, $0.offset) })
            let grouped = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
            var next = model.session.tabs
            for i in next.indices {
                guard let organization = grouped[next[i].id] else { continue }
                next[i].pinned = organization.pinned; next[i].folderID = organization.folderID
                next[i].parentID = organization.parentID
            }
            next.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
            model.session.tabs = next
        case "stackTabs":
            // Vivaldi's stacks: the two tabs share a new folder named after the target's site.
            guard let model, !model.isPrivate, let id, let onto = (command["onto"] as? String).flatMap(UUID.init(uuidString:)), id != onto,
                  let spaceIndex = app.library.spaces?.firstIndex(where: { $0.id == model.session.spaceID }),
                  let target = model.session.tabs.first(where: { $0.id == onto }), model.session.tabs.contains(where: { $0.id == id }) else { return }
            let host = target.url?.host ?? ""
            app.createFolder(name: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host.isEmpty ? "Stack" : host, spaceID: model.session.spaceID)
            guard let folder = app.library.spaces?[spaceIndex].folders.last else { return }
            for i in model.session.tabs.indices where [id, onto].contains(model.session.tabs[i].id) { model.session.tabs[i].folderID = folder.id; model.session.tabs[i].parentID = nil }
        case "createFolder":
            if let name = command["name"] as? String { app.createFolder(name: name, spaceID: model?.session.spaceID, parentID: id) }
        case "nestFolder":
            if let id { app.nestFolder(id, parentID: (command["parent"] as? String).flatMap(UUID.init(uuidString:)), spaceID: model?.session.spaceID) }
        case "createSpace":
            if let model, let name = command["name"] as? String, let id = app.createSpace(name: name, profileID: profileID) { model.switchSpace(id) }
        case "createProfile":
            if let name = command["name"] as? String, !name.isEmpty, app.library.profiles.count < 20 { app.library.profiles.append(Profile(name: String(name.prefix(80)))) }
        case "renameFolder", "deleteFolder", "toggleFolder":
            guard let model, let spaceIndex = app.library.spaces?.firstIndex(where: { $0.id == model.session.spaceID }),
                  let folderIndex = app.library.spaces?[spaceIndex].folders.firstIndex(where: { $0.id == id }), let id else { return }
            if operation == "toggleFolder" { app.toggleFolder(id, spaceID: model.session.spaceID) }
            else if operation == "renameFolder", let name = command["name"] as? String { app.library.spaces?[spaceIndex].folders[folderIndex].name = String(name.prefix(80)) }
            else {
                // Its tabs and subfolders move up to the folder it was in.
                let parent = app.library.spaces?[spaceIndex].folders[folderIndex].parentID
                for i in model.session.tabs.indices where model.session.tabs[i].folderID == id { model.session.tabs[i].folderID = parent }
                for i in app.library.spaces?[spaceIndex].folders.indices ?? 0..<0 where app.library.spaces?[spaceIndex].folders[i].parentID == id {
                    app.library.spaces?[spaceIndex].folders[i].parentID = parent
                }
                app.library.spaces?[spaceIndex].folders.removeAll { $0.id == id }
            }
        case "renameSpace":
            if let name = command["name"] as? String, let index = app.library.spaces?.firstIndex(where: { $0.id == id }) { app.library.spaces?[index].name = String(name.prefix(80)) }
        case "moveTabToSpace":
            if let id, let raw = command["spaceID"] as? String, let space = UUID(uuidString: raw) { model?.moveTab(id, toSpace: space) }
        case "reorderSpaces":
            guard let model, !model.isPrivate, var spaces = app.library.spaces,
                  let raw = command["ids"] as? [String] else { return }
            let ids = raw.compactMap(UUID.init(uuidString:))
            let indices = spaces.indices.filter { spaces[$0].profileID == model.session.profileID }
            let owned = indices.map { spaces[$0] }
            guard ids.count == raw.count, Set(ids).count == ids.count,
                  Set(ids) == Set(owned.map(\.id)) else { return }
            let ordered = ids.compactMap { id in owned.first { $0.id == id } }
            for (i, index) in indices.enumerated() { spaces[index] = ordered[i] }
            app.library.spaces = spaces
        case "reorderFolders":
            guard let model, !model.isPrivate,
                  let index = app.library.spaces?.firstIndex(where: { $0.id == model.session.spaceID }),
                  let folders = app.library.spaces?[index].folders,
                  let raw = command["ids"] as? [String] else { return }
            let ids = raw.compactMap(UUID.init(uuidString:))
            guard ids.count == raw.count, Set(ids).count == ids.count, Set(ids) == Set(folders.map(\.id)) else { return }
            app.library.spaces?[index].folders = ids.compactMap { id in folders.first { $0.id == id } }
        case "saveNamedSetup", "replaceNamedSetup", "renameNamedSetup", "deleteNamedSetup":
            do {
                let action=operation=="saveNamedSetup" ? "save" : operation=="replaceNamedSetup" ? "replace" : operation=="renameNamedSetup" ? "rename" : "delete"
                app.library=try RustCore.decode(LibraryState.self,from:RustCore.request(["op":"manageNamedSetup","action":action,"value":RustCore.encoded(app.library),
                    "id":command["id"] ?? NSNull(),"name":command["name"] ?? "","configuration":command["configuration"] ?? NSNull(),
                    "requirements":command["requirements"] as? [String] ?? app.configurationModuleRequirements]))
                if action=="replace" || action=="delete" {app.windows.values.compactMap(\.model).forEach{$0.synchronizeSplit(force:true)}}
                app.notice=nil;editorResult(action:operation,success:true,message:action=="save" ? "Setup saved." : action=="rename" ? "Setup renamed." : action=="delete" ? "Setup deleted." : "Setup replaced.")
            } catch {app.notice=error.localizedDescription;editorResult(action:operation,success:false,message:error.localizedDescription)}
        case "applyConfiguration":
            do {
                guard let object=command["configuration"],let data=try? JSONSerialization.data(withJSONObject:object),
                      var configuration=try? JSONDecoder().decode(Configuration.self,from:data) else {throw ValidationError("That appearance could not be saved.")}
                configuration.normalize()
                let spaceID=command["space"] as? Bool == true ? model?.session.spaceID : nil
                if let requirements=command["requirements"] as? [String],!requirements.isEmpty {
                    guard try app.applySetup(configuration,requirements:requirements,approvalTitle:"Restore this setup’s tools?",spaceID:spaceID) else {
                        editorResult(action:operation,success:false,message:"Appearance was not applied. Your draft is still here.");return
                    }
                } else {
                    guard app.applyConfiguration(configuration,to:spaceID) else {throw ValidationError(app.notice ?? "The appearance could not be applied.")}
                }
                app.notice=nil;editorResult(action:operation,success:true,message:"Appearance saved.")
            } catch {app.notice=error.localizedDescription;editorResult(action:operation,success:false,message:error.localizedDescription)}
        case "sidebarWidth":
            if let model, let width = command["value"] as? Double, width.isFinite {
                var configuration = model.configuration; configuration.layout.tabsWidth = min(340, max(200, width))
                app.applyConfiguration(configuration, to: model.session.spaceID)
            }
        case "preference":
            switch command["key"] as? String {
            case "search": if let value = command["value"] as? String, let search = SearchProvider(rawValue: value) { app.library.preferences.search = search }
            case "blockTrackers": if let value = command["value"] as? Bool { app.library.preferences.blockTrackers = value; for window in app.windows.values { window.model?.updateBlockingPolicy() }; ChromiumRuntime.shared.updateProtection(blocking:value) }
            case "blockPopups": if let value = command["value"] as? Bool { app.library.preferences.blockPopups = value; for window in app.windows.values { window.model?.updatePopupPolicy() }; ChromiumRuntime.shared.updateProtection() }
            case "restoreSession": if let value = command["value"] as? Bool { app.library.preferences.restoreSession = value }
            case "automaticUpdates": if let value = command["value"] as? Bool { DistributionManager.shared.automaticUpdates = value }
            case "startGuideHidden": if let value = command["value"] as? Bool { app.library.preferences.startGuideHidden = value }
            case "blockAds": if let value = command["value"] as? Bool { app.library.preferences.blockAds = value; for window in app.windows.values { window.model?.updateBlockingPolicy() } }
            default: _ = features.setPreference(command["key"] as? String ?? "", command["value"])
            }
        case "finishSetup": if let values = command["setup"] as? [String: Any] { finishSetup(values, configuration: command["configuration"]) }
        case "importBookmarks": imported = app.importBookmarks(profileID: profileID) || imported
        case "exportBookmarks": app.exportBookmarks(profileID: profileID)
        case "removeBookmark": if let id { app.library.bookmarks.removeAll { $0.id == id && $0.profileID == profileID } }
        case "clearHistory": app.library.history.removeAll { $0.profileID == profileID }
        case "restoreArchived":
            if let id, let space = model?.session.spaceID { app.restoreArchivedTab(id, spaceID: space); model?.selectTab(id) }
        case "defaultBrowser": setDefaultBrowser()
        case "checkUpdates": DistributionManager.shared.checkForUpdates(dataDirectory: app.dataDirectory)
        case "downloadUpdate":
            if let asset = DistributionManager.shared.available.first { DistributionManager.shared.install(asset, dataDirectory: app.dataDirectory) }
        case "importInstaller": DistributionManager.shared.importInstaller(dataDirectory: app.dataDirectory)
        case "discardUpdate": DistributionManager.shared.discardPending()
        case "restartUpdate": DistributionManager.shared.requestRestart()
        case "cancelUpdate": DistributionManager.shared.cancel()
        case "newWindow": openWindow?(false)
        case "tabToNewWindow":
            // The new window shows this Space with the tab selected; its live page moves there.
            guard let model, !model.isPrivate, let id, let spaceID = model.session.spaceID, model.session.tabs.count > 1 else { return }
            if model.session.selectedTabID == id, let other = model.session.tabs.first(where: { $0.id != id }) { model.selectTab(other.id) }
            app.pendingWindowTab = (spaceID, id)
            openWindow?(false)
        case "privateWindow": openWindow?(true)
        case "downloadCancel", "downloadPause", "downloadResume", "downloadReveal", "downloadOpen":
            guard let center = downloadCenter ?? model?.downloads, let item = center.items.first(where: { $0.id == id }) else { return }
            if operation == "downloadCancel" { center.cancel(item) }
            else if operation == "downloadPause" || operation == "downloadResume" { center.setPaused(item, operation == "downloadPause") }
            else if let url = item.destination, item.succeeded {
                if operation == "downloadOpen" { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        case "toggleModule":
            if let raw = command["id"] as? String, let module = app.installedModules.first(where: { $0.id == raw }) { app.toggleModule(module); applyActiveStyle(raw) }
        case "installModule":
            if let raw = command["id"] as? String, app.catalog.contains(where: { $0.id == raw }) { app.install(raw); applyActiveStyle(raw) }
        case "repairModule":
            if let raw = command["id"] as? String, let module = app.installedModules.first(where: { $0.id == raw }) { app.reinstallWorker(module) }
        case "uninstallModule":
            if let raw = command["id"] as? String, let module = app.installedModules.first(where: { $0.id == raw }) { app.uninstall(module) }
        case "setModuleSetting":
            guard let raw = command["id"] as? String, let key = command["key"] as? String,
                  let module = app.installedModules.first(where: { $0.id == raw }),
                  let schema = module.manifest.settings?.first(where: { $0.id == key }),
                  let value = command["value"],
                  let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
                  let decoded = try? JSONDecoder().decode(ModuleValue.self, from: data) else { return }
            app.setModuleSetting(schema,value:decoded,moduleID:raw)
        case "importCatalog": app.importCatalog()
        case "removeCatalog":
            if let name = command["id"] as? String { app.removeCatalog(named:name) }
        case "importModule": app.importModule()
        case "webStore": model?.newTab(url: URL(string: "https://chromewebstore.google.com/"), engine: .chromium)
        case "installExtension", "extensionAction", "openExtensionOptions", "removeExtension":
            // Chromium's own privileged management surface preserves its permission
            // and local-install checks; it opens as a normal Neutrino-owned tab.
            model?.newTab(engine: .chromium)
            (model?.activeWebTab as? ChromiumTab)?.showExtensions()
            sendAction(["op": "screen", "value": "browse"])
        case "reloadTab": if let model, let id, model.session.tabs.contains(where: { $0.id == id }) { model.webTab(id).reload() }
        case "useWebKit": if let model { model.reopenTab(id ?? model.session.selectedTabID, with: .webkit) }
        case "find": model?.activeWebTab.find(command["value"] as? String ?? "", backwards: command["backwards"] as? Bool == true)
        case "projectLibrary":
            if let section = command["section"] as? String { librarySection = section; libraryPage = 0 }
        case "libraryPage":
            libraryPage = max(0, min(100_000, (command["value"] as? String).flatMap(Int.init) ?? 0))
        case "selectNote":
            if model?.isPrivate != true, app.library.notes.contains(where: { $0.id == id && $0.profileID == profileID }) { selectedNoteID = id }
        case "noteFromPage", "quoteSelection":
            guard let model,!model.isPrivate,let url=model.selectedTab.url else{return}
            let tab=model.activeWebTab,revision=tab.navigationRevision,profile=model.session.profileID,title=model.selectedTab.title
            let sourcePageToken=(tab as? ChromiumTab)?.selectedSourcePageToken
            Task { @MainActor in
                do {
                    let quote=operation=="quoteSelection" ? try await tab.selectedText() : ""
                    guard !app.finalQuitDataFrozen,!model.isClosed,model.session.profileID==profile,model.activeWebTab===tab,tab.navigationRevision==revision else{return}
                    if operation=="quoteSelection" && quote.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {app.notice="Select text on the page, then choose Quote.";return}
                    guard let prepared=try RustCore.request(["op":"prepareNote","url":url.absoluteString,"title":title,"quote":quote]) as? [String:String] else{return}
                    let original=app.library.notes
                    do {
                        let noteID=try app.createModuleNote(profileID:profile)
                        try app.updateModuleNote(id:noteID,profileID:profile,field:"title",value:prepared["title"] ?? title)
                        try app.updateModuleNote(id:noteID,profileID:profile,field:"text",value:prepared["text"] ?? "")
                        if let index = app.library.notes.firstIndex(where:{$0.id==noteID}) {
                            app.library.notes[index].spaceID = model.session.spaceID
                            app.library.notes[index].sourceTabID = model.session.selectedTabID
                            app.library.notes[index].sourcePageToken = sourcePageToken
                            app.library.notes[index].sourceURL = URL(string: prepared["sourceURL"] ?? "")
                            app.library.notes[index].sourceTitle = prepared["sourceTitle"]
                            app.library.notes[index].quotedText = prepared["quote"]
                        }
                        selectedNoteID=noteID;notesQuery="";libraryPage=0
                    } catch {app.library.notes=original;throw error}
                    scheduleSync()
                }catch{app.notice=error.localizedDescription}
            }
        case "createNote":
            guard model?.isPrivate != true else { return }
            app.perform {
                selectedNoteID = try app.createModuleNote(profileID: profileID);notesQuery="";libraryPage=0
                if let index=app.library.notes.firstIndex(where:{$0.id==selectedNoteID}) { app.library.notes[index].spaceID=model?.session.spaceID }
            }
        case "notesQuery":notesQuery=String((command["value"] as? String ?? "").prefix(160));libraryPage=0
        case "notesScope": allNotes = command["value"] as? String == "all"; libraryPage = 0
        case "openNoteSource":
            guard model?.isPrivate != true, let model, let id,
                  let note=app.library.notes.first(where:{$0.id==id && $0.profileID==profileID}),
                  let url=note.sourceURL, AddressResolver.isWebURL(url) else{return}
            guard let target=noteSourceTarget(note,model:model) else{return}
            if let raw=target["spaceID"] as? String,let spaceID=UUID(uuidString:raw),
               app.library.spaces?.contains(where:{$0.id==spaceID && $0.profileID==profileID}) == true,
               model.session.spaceID != spaceID { model.switchSpace(spaceID) }
            if let raw=target["tabID"] as? String,let tabID=UUID(uuidString:raw),model.session.tabs.contains(where:{$0.id==tabID}) {
                model.selectTab(tabID)
                if let nativeID=target["pageID"] as? Int { (model.activeWebTab as? ChromiumTab)?.selectInterfacePage(nativeID) }
                else if target["restoreURL"] != nil,let page=model.activeWebTab as? ChromiumTab {
                    sourceRestoreTask=Task { @MainActor [weak self,weak model] in
                        let deadline=ContinuousClock.now.advanced(by:.seconds(30))
                        while ContinuousClock.now < deadline {
                            guard !Task.isCancelled,let self,!self.stopped,let model,!app.finalQuitDataFrozen,!model.isClosed,
                                  model.session.profileID==profileID,model.session.selectedTabID==tabID,
                                  model.activeWebTab===page,self.selectedNoteID==note.id,
                                  app.library.notes.contains(where:{$0.id==note.id && $0.profileID==profileID}) else{return}
                            if page.isReadyForEngineSwitch,page.noteSourcePages.contains(where:{$0["url"] as? String == url.absoluteString}),
                               let resolved=self.noteSourceTarget(note,model:model),
                               resolved["tabID"] as? String == tabID.uuidString,let nativeID=resolved["pageID"] as? Int {
                                page.selectInterfacePage(nativeID);self.scheduleSync();return
                            }
                            do {try await Task.sleep(for:.milliseconds(100))} catch{return}
                        }
                        guard !Task.isCancelled,let self,!self.stopped,let model,!self.app.finalQuitDataFrozen,
                              !model.isClosed,model.session.profileID==profileID,self.selectedNoteID==note.id else{return}
                        self.app.notice="The source page could not be restored. Retry Open source when the tab finishes loading."
                    }
                }
            } else { model.newTab(url:url) }
            selectedNoteID = note.id; notesQuery = ""; libraryPage = 0
            if note.spaceID != nil && note.spaceID != model.session.spaceID { allNotes = true }
        case "saveNote":
            guard model?.isPrivate != true, let id,
                  let value = command["value"] as? [String: String], let content = value["text"], let field = value["field"] else { return }
            app.perform { try app.updateModuleNote(id: id, profileID: profileID, field: field == "body" ? "text" : field, value: content) }
        case "deleteNote":
            guard model?.isPrivate != true, let id else { return }
            app.perform { try app.deleteModuleNote(id: id, profileID: profileID) }
            if selectedNoteID == id { selectedNoteID = nil }
        case "credentialFill":
            guard let model, let key = command["id"] as? String else { return }
            Task { @MainActor in
                do {
                    guard let data = try SecureVault.get(account: key, service: LocalCredential.service(profileID)), model.session.profileID == profileID else { return }
                    let credential = try JSONDecoder().decode(LocalCredential.self, from: data)
                    try await model.activeWebTab.fillCredential(credential); app.notice = "Login filled on the matching website."
                } catch { app.notice = error.localizedDescription }
            }
        case "saveCredential":
            do {
                guard model?.isPrivate != true, let origin = command["origin"] as? String, let url = URL(string: origin),
                      let username = command["username"] as? String, let password = command["password"] as? String else { return }
                let credential = LocalCredential(origin: try LocalCredential.origin(for: url), username: username, password: password)
                try credential.save(profile: profileID); refreshCredentialMetadata(profileID: profileID); app.notice = "Login saved in Keychain."
            } catch { app.notice = error.localizedDescription }
        case "credentialDelete":
            if let key = command["id"] as? String, model?.isPrivate != true {
                app.perform { try SecureVault.delete(account: key, service: LocalCredential.service(profileID)) }
                refreshCredentialMetadata(profileID: profileID)
            }
        case "saveAI": saveAI(command)
        case "signIn", "disconnectAI":
            guard accountTask==nil else{return}
            accountTask=Task { @MainActor [weak self] in
                guard let self,!self.stopped,!Task.isCancelled else{return}
                defer {self.accountTask=nil;self.scheduleSync()}
                if operation=="signIn" {await ChatGPTAccount.shared.signIn()} else {await ChatGPTAccount.shared.disconnect()}
            }
        case "disableAI": app.library.preferences.ai = nil
        case "cancelAI": accountTask?.cancel(); ChatGPTAccount.shared.cancelSignIn(); assistantGeneration = UUID(); assistantTask?.cancel(); assistantTask = nil
        case "restoreLayout": app.applyConfiguration(Configuration(), to: model?.session.spaceID); app.applyConfiguration(Configuration()); app.notice = "Default appearance restored."
        case "resetModules": app.resetModules()
        case "retrySave": Task { @MainActor in if await app.flush() { app.notice = "Browser data saved." } }
        case "showDataFolder": NSWorkspace.shared.open(app.dataDirectory)
        case "assistant": askAssistant(command)
        case "exitFocus": model?.exitFocus()
        case "toggleFocus":
            guard let model else { return }; if model.focusMode { model.exitFocus() } else { model.enterFocus() }
        case "retryResources":
            resourcesOpen = false; scheduleSync()
        case "readerSpeak":
            if command["value"] as? String == "stop" { readerVoice?.stop(); break }
            if readerVoice == nil { readerVoice = ReaderVoice { [weak self] in self?.scheduleSync() } }
            readerVoice?.speak(assistantResponse)
        case "reader":
            guard let model else { return }; assistantTask?.cancel()
            let tab = model.activeWebTab, revision = tab.navigationRevision, profile = model.session.profileID
            let generation = UUID(); assistantGeneration = generation
            assistantTask = Task { @MainActor in
                defer { if assistantGeneration == generation { assistantTask = nil }; scheduleSync() }
                do {
                    let content = try await app.readerText(from: tab)
                    guard !Task.isCancelled, assistantGeneration == generation, !model.isClosed, model.session.profileID == profile,
                          model.activeWebTab === tab, tab.navigationRevision == revision,
                          app.library.profiles.contains(where: { $0.id == profile }) else { return }
                    responseDocument = model.session.selectedTabID.uuidString + ":" + revision.uuidString
                    assistantResponse = content; readerImages = []; sendAction(["op": "screen", "value": "reader"])
                    let images = await ReaderImages.load(from: tab)
                    guard assistantGeneration == generation, tab.navigationRevision == revision, !images.isEmpty else { return }
                    readerImages = images
                } catch is CancellationError {} catch { if !Task.isCancelled && model.session.profileID == profile { app.notice = error.localizedDescription } }
            }
        case "capture":
            guard let model else { return }
            Task { @MainActor in
                do {
                    let specification = try app.pageCaptureSpecification()
                    let image = try await model.activeWebTab.capturePNG()
                    let panel = NSSavePanel(); panel.nameFieldStringValue = specification.filename
                    if panel.runModal() == .OK, let url = panel.url { try image.write(to: url, options: .atomic) }
                } catch { app.notice = error.localizedDescription }
            }
        default:
            if !features.perform(operation, command) { app.notice = "This action is unavailable in the current browsing context." }
        }
    }
    private func noteSourceTarget(_ note:Note,model:BrowserModel) -> [String:Any]? {
        guard let url=note.sourceURL else{return nil}
        let profileID=model.session.profileID
        let live=note.sourceTabID.flatMap { tabID in
            app.tabOwnership.owner(of:tabID).flatMap { app.windows[$0]?.model?.cachedEngineTab(tabID,profileID:profileID) } as? ChromiumTab
        }
        let profileSpaces=(app.library.spaces ?? []).filter{$0.profileID==profileID}
        let spaces=profileSpaces.map{["id":$0.id.uuidString,"profileID":$0.profileID.uuidString]}
        let candidates=profileSpaces.flatMap { space in
            space.tabs.filter{$0.id==note.sourceTabID || $0.url==url}.map { tab -> [String:Any] in
                ["id":tab.id.uuidString,"profileID":space.profileID.uuidString,"spaceID":space.id.uuidString,
                 "url":tab.url?.absoluteString ?? "","pages":tab.id==note.sourceTabID ? live?.noteSourcePages ?? [] : [],
                 "restorableURLs":tab.id==note.sourceTabID ? tab.chromiumPages?.compactMap{$0.url?.absoluteString} ?? [] : []]
            }
        }
        return try? RustCore.request(["op":"resolveNoteSource","profileID":profileID.uuidString,
            "spaceID":model.session.spaceID?.uuidString ?? "","spaces":spaces,"candidates":candidates,
            "note":["profileID":note.profileID.uuidString,"spaceID":note.spaceID?.uuidString ?? "",
                    "sourceTabID":note.sourceTabID?.uuidString ?? "","sourceURL":url.absoluteString,
                    "sourcePageToken":note.sourcePageToken ?? ""]]) as? [String:Any]
    }
    private func refreshCredentialMetadata(profileID: UUID) {
        guard model?.isPrivate != true else { credentialMetadata = []; return }
        // Keychain account labels contain origin + username; values stay unread.
        credentialMetadata = ((try? SecureVault.accounts(service: LocalCredential.service(profileID))) ?? []).prefix(200).compactMap { key in
            let parts = key.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return ["id": key, "origin": String(parts[0]), "username": String(parts[1])]
        }
    }
    private func applyActiveStyle(_ id: String) {
        guard let model,let module=app.installedModules.first(where:{$0.id==id && $0.enabled}),
              let definition=app.declarativeDefinition(module.manifest.capability) else{return}
        var c=model.configuration
        switch module.manifest.capability {
        case .theme: if let theme=definition.theme {c.theme=theme}
        case .layout: if let layout=definition.layout {c.layout=layout}
        case .tabSystem: c.layout.treeTabs=definition.treeTabs
        case .icons: c.theme.iconPack="module"
        default:return
        }
        app.applyConfiguration(c,to:model.session.spaceID)
    }
    private func finishSetup(_ values: [String: Any], configuration computed: Any? = nil) {
        guard !app.onboardingSaving, !app.library.preferences.completedOnboarding,
              let profile = values["profile"] as? String, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let space = values["space"] as? String, !space.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        app.onboardingSaving = true
        app.library.profiles[0].name = String(profile.prefix(80)); app.library.normalizeSpaces()
        app.library.spaces?[0].name = String(space.prefix(80))
        app.library.preferences.search = (values["search"] as? String).flatMap(SearchProvider.init(rawValue:)) ?? .duckDuckGo
        app.library.preferences.blockTrackers = values["blockTrackers"] as? Bool ?? true
        app.library.preferences.blockPopups = values["blockPopups"] as? Bool ?? true
        app.library.preferences.restoreSession = values["restoreSession"] as? Bool ?? true
        app.library.preferences.blockAds = values["blockAds"] as? Bool ?? true
        if let model, !model.isPrivate {
            for case let panel as [String: Any] in (values["webPanels"] as? [Any] ?? []).prefix(12) {
                guard let raw = panel["url"] as? String, let url = URL(string: raw), AddressResolver.isWebURL(url),
                      !(app.library.preferences.webPanels ?? []).contains(where: { $0.profileID == model.session.profileID && $0.url == url }) else { continue }
                let title = String((panel["title"] as? String ?? url.host ?? "Panel").prefix(80))
                app.library.preferences.webPanels = (app.library.preferences.webPanels ?? []) + [WebPanel(profileID: model.session.profileID, title: title, url: url)]
            }
        }
        let modules = (values["modules"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
        app.applySetupModules(modules)
        // A theme, layout, icon set or tab system chosen here restyles the browser after its preset.
        let lookModules = { [weak self] in
            guard let self else { return }
            for (id, on) in modules where on { self.applyActiveStyle(id) }
        }
        var configuration = Configuration()
        // Rust computes the chosen browser's configuration; older shells send only the preset.
        if let computed, let data = try? JSONSerialization.data(withJSONObject: computed),
           let decoded = try? JSONDecoder().decode(Configuration.self, from: data) {
            app.applyConfiguration(decoded)
            for case let value as String in (values["favorites"] as? [Any] ?? []).prefix(12) {
                guard let url = URL(string: value), AddressResolver.isWebURL(url), let model else { continue }
                if decoded.theme.preset == "arc" {
                    // Arc's Favorites are shared by every Space of the Profile.
                    let profile = model.session.profileID
                    guard !(app.library.preferences.favorites ?? []).contains(where: { $0.profileID == profile && $0.url.host == url.host }) else { continue }
                    app.library.preferences.favorites = (app.library.preferences.favorites ?? []) + [FavoriteSite(profileID: profile, title: url.host ?? "Site", url: url)]
                    continue
                }
                guard !model.session.tabs.contains(where: { $0.pinned && $0.url?.host == url.host }) else { continue }
                model.newTab(url: url); model.pinTab(model.session.selectedTabID)
            }
            lookModules()
            finishOnboarding()
            return
        }
        if let id=values["preset"] as? String,
           let raw=try? RustCore.request(["op":"appearancePreset","id":id]),
           let data=try? JSONSerialization.data(withJSONObject:raw),
           let selected=try? JSONDecoder().decode(Configuration.self,from:data) {configuration=selected}
        configuration.theme.accent = (values["accent"] as? String).flatMap(Accent.init(rawValue:)) ?? .purple
        configuration.theme.colorMode = (values["appearance"] as? String).flatMap(ColorMode.init(rawValue:)) ?? .system
        configuration.layout.tabs = (values["layout"] as? String).flatMap(TabPlacement.init(rawValue:)) ?? .leading
        app.applyConfiguration(configuration)
        lookModules()
        finishOnboarding()
    }
    private func finishOnboarding() {
        Task { @MainActor in
            app.library.preferences.completedOnboarding = true
            if !(await app.flush()) { app.library.preferences.completedOnboarding = false; app.notice = "Your setup could not be saved. Your choices are kept here; try again." }
            app.onboardingSaving = false
            scheduleSync()
        }
    }
    /// Whether macOS currently opens web links with this copy of Neutrino.
    private var isDefaultBrowser: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
    private func setDefaultBrowser() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "https") { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.defaultStatus = error.localizedDescription; self.scheduleSync(); return }
                NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http") { [weak self] error in
                    Task { @MainActor in self?.defaultStatus = error?.localizedDescription ?? "Neutrino is your default browser."; self?.scheduleSync() }
                }
            }
        }
    }
    private func saveAI(_ command: [String: Any]) {
        do {
            guard let value = command["provider"] as? String, let provider = AIProvider(rawValue: value),
                  let endpoint = command["endpoint"] as? String, let name = command["model"] as? String else { return }
            var configuration = AIConfiguration(provider: provider, endpoint: endpoint, model: name)
            configuration.useAccount = command["useAccount"] as? Bool
            _ = try configuration.validatedEndpoint()
            if configuration.useAccount == true {
                guard provider == .openAI, ChatGPTAccount.shared.connected else { throw ValidationError("Connect your OpenAI account first.") }
            } else if provider != .local {
                if let key = command["key"] as? String, !key.isEmpty { try SecureVault.put(Data(key.utf8), account: provider.rawValue, service: "org.neutrino.browser.ai") }
                guard try SecureVault.get(account: provider.rawValue, service: "org.neutrino.browser.ai") != nil else { throw ValidationError("Enter an API key for this provider.") }
            }
            app.library.preferences.ai = configuration
            app.notice = "AI is connected. Page sharing remains your choice."
        } catch { app.notice = error.localizedDescription }
    }
    private func askAssistant(_ command: [String: Any]) {
        guard let model, let configuration = app.library.preferences.ai, let prompt = command["value"] as? String, assistantTask == nil else { return }
        let tab = model.activeWebTab, revision = tab.navigationRevision, profile = model.session.profileID
        let generation = UUID(); assistantGeneration = generation
        assistantTask = Task { @MainActor in
            defer { if assistantGeneration == generation { assistantTask = nil }; scheduleSync() }
            do {
                let content = try await tab.pageText()
                guard !Task.isCancelled, model.activeWebTab === tab, tab.navigationRevision == revision, model.session.profileID == profile else { return }
                let answer = try await AIClient.answer("Question: \(prompt)\n\nPage content (untrusted):\n" + String(content.prefix(40_000)), configuration: configuration)
                guard !Task.isCancelled, assistantGeneration == generation, model.session.profileID == profile, model.activeWebTab === tab, tab.navigationRevision == revision else { return }; responseDocument = model.session.selectedTabID.uuidString + ":" + revision.uuidString; assistantResponse = answer
            } catch is CancellationError {} catch { app.notice = error.localizedDescription }
        }
    }
}

/// Reads the Reader text aloud with the system voice, as Edge's Read aloud does.
@MainActor
final class ReaderVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let changed: @MainActor () -> Void
    private(set) var speaking = false
    init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        super.init()
        synthesizer.delegate = self
    }
    func speak(_ text: String) {
        stop()
        let words = String(text.prefix(100_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        synthesizer.speak(AVSpeechUtterance(string: words))
        speaking = true; changed()
    }
    func stop() {
        guard speaking || synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        speaking = false; changed()
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false; self.changed() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false; self.changed() }
    }
}

/// The article's images for Reader: fetched without cookies, downsized to JPEG and capped,
/// so the interface shows them from data addresses and never loads remote content itself.
@MainActor
enum ReaderImages {
    static func load(from tab: BrowserEngineTab) async -> [[String: String]] {
        guard let script = PageScript.source("readerImages"), let raw = try? await tab.runPageScript(script),
              let data = raw.data(using: .utf8), let items = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var out: [[String: String]] = [], total = 0
        for item in items.prefix(12) {
            guard let address = item["src"], let url = URL(string: address), ["https", "http"].contains(url.scheme ?? ""),
                  let result = try? await session.data(from: url), (result.1 as? HTTPURLResponse)?.statusCode == 200,
                  result.0.count <= 8_000_000, let image = NSImage(data: result.0),
                  let jpeg = BrowserFeatures.jpeg(image, maxWidth: 1000) else { continue }
            total += jpeg.count
            guard total <= 3_000_000 else { break }
            out.append(["src": "data:image/jpeg;base64," + jpeg.base64EncodedString(),
                        "alt": String((item["alt"] ?? "").prefix(200)), "anchor": String((item["anchor"] ?? "").prefix(80))])
        }
        return out
    }
}
