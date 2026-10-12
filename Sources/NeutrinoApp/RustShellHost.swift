// SPDX-License-Identifier: MPL-2.0
import AppKit
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
        guard let data = try? JSONSerialization.data(withJSONObject: request), data.count <= 8_388_608,
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
    private var librarySection = "bookmarks"
    private var libraryPage = 0
    private var engineObservations = Set<AnyCancellable>()
    private var observedEngines = Set<ObjectIdentifier>()
    private var responseDocument: String?
    private var pendingSync: Task<Void, Never>?
    private var renderGeneration = 0
    private var showingOverlay = true
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
    private var cachedIconSymbols: [String:String] = [:]
    private var cachedIconImages: [String:String] = [:]
    private var stopped = false
    private var projectedProfileID: UUID?
    private var downloadScreenOpened = false
    private var imported = false
    private var defaultStatus = ""
    private var assistantResponse = ""
    private var assistantTask: Task<Void, Never>?
    private var assistantGeneration = UUID()
    private var previewStep: Int?
    private let isPreview: Bool
    private var lastSheet: BrowserSheet?
    private var lastPanel: BrowserPanel?
    private let openWindow: ((Bool) -> Void)?
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
            let blocked = MainActor.assumeIsolated {
                guard let self, !self.stopped,
                      let window = self.container.window, ownedWindowIDs.contains(ObjectIdentifier(window)) else { return false }
                if mouseDown {
                    if let menu = self.nonModalMenuRect, let screenPoint {
                        let point = self.container.convert(window.convertPoint(fromScreen:screenPoint),from:nil)
                        if !menu.contains(point), self.container.nativeHit(point) { self.sendAction(["op":"escape"]) }
                    }
                    return false
                }
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
                if closeTab, self.ready, let model = self.model, !model.isClosed {
                    self.sendAction(["op":"closeTab","id":model.session.selectedTabID.uuidString])
                    return true
                }
                return false
            }
            return blocked ? nil : event
        }
        chrome.setValue(false, forKey: "drawsBackground")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "neutrino")
        resourceWorker.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &subscriptions)
        app.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &subscriptions)
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
                self?.sendAction(["op": "menu", "value": "find"])
            }.store(in: &subscriptions)
            NotificationCenter.default.publisher(for: .neutrinoOpenBrowserWindow).sink { [weak self] notification in
                guard notification.object as? UUID == model.session.id else { return }
                self?.openWindow?(notification.userInfo?["private"] as? Bool == true)
            }.store(in: &subscriptions)
        }
        model?.shellAction = { [weak self] request in self?.sendAction(request) }
        chrome.load(URLRequest(url: URL(string: "neutrino-ui://shell/index.html")!))
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        resourceWorker.stop()
        editingEngines.forEach { $0.setInterfaceEditing(false, owner: editingOwner) }; editingEngines.removeAll()
        if let editingInputMonitor { NSEvent.removeMonitor(editingInputMonitor) }; editingInputMonitor = nil
        pendingSync?.cancel(); assistantTask?.cancel(); model?.shellAction = nil; subscriptions.removeAll(); downloadObservations.removeAll(); engineObservations.removeAll(); observedEngines.removeAll()
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
    private func observeDownloads(_ center: DownloadCenter?) {
        let ids = center?.items.map(\.id) ?? []
        guard observedDownloads !== center || observedDownloadIDs != ids else { return }
        observedDownloads = center; observedDownloadIDs = ids; downloadObservations.removeAll()
        center?.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &downloadObservations)
        for item in center?.items ?? [] { item.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &downloadObservations) }
    }
    private func encoded<T: Encodable>(_ value: T) -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)) ?? NSNull() }
    private func synchronize() -> [String: Any] {
        if let center = downloadCenter {
            // Auxiliary windows receive only their own download capability. They
            // must not inherit the default Profile when no BrowserModel exists.
            observeDownloads(center)
            let snapshot: [String: Any] = ["downloadsWindow":true,"completedOnboarding":true,
                "frozen":app.finalQuitDataFrozen,"private":true,
                "downloads":center.items.map { ["id":$0.id.uuidString,"name":$0.name,"status":$0.status,"complete":!$0.active && $0.destination != nil] as [String:Any] }]
            return stamped(handle.dispatch(["op":"sync","snapshot":snapshot]))
        }
        let update = DistributionManager.shared
        let profileID = model?.session.profileID ?? app.library.profiles[0].id
        if projectedProfileID != profileID {
            projectedProfileID = profileID; assistantGeneration = UUID(); assistantTask?.cancel(); assistantTask = nil
            assistantResponse = ""; credentialMetadata = []; selectedNoteID = nil; libraryPage = 0
        }
        let space = model?.space
        observeDownloads(downloadCenter ?? model?.downloads)
        let regular = model?.isPrivate != true
        let bookmarks = regular ? app.library.bookmarks.filter { $0.profileID == profileID } : []
        let notes = regular ? app.library.notes.filter { $0.profileID == profileID } : []
        let history = regular ? Array(app.library.history.filter { $0.profileID == profileID }.reversed()) : []
        let count = librarySection == "notes" ? notes.count : librarySection == "history" ? history.count : bookmarks.count
        libraryPage = min(libraryPage, max(0, (count - 1) / 40))
        let offset = libraryPage * 40
        let selectedNote = notes.first { $0.id == selectedNoteID }
        var snapshot: [String: Any] = [
            "completedOnboarding": !isPreview && app.library.preferences.completedOnboarding,
            "smoke": model != nil && CommandLine.arguments.contains("--smoke-test"),
            "private": model?.isPrivate ?? false, "frozen": app.finalQuitDataFrozen,
            "saving": app.onboardingSaving, "spaceName": space?.name ?? "Everyday",
            "profileName": model?.profile.name ?? app.library.profiles[0].name,
            "preferences": encoded(app.library.preferences),
            "configuration": encoded(model?.configuration ?? app.library.preferences.configuration),
            "profiles": encoded(app.library.profiles),
            "spaces": encoded((app.library.spaces ?? []).map { SpaceIdentity(id: $0.id, name: $0.name, profileID: $0.profileID) }),
            "folders": encoded(space?.folders ?? []), "archived": (space?.archivedTabs ?? []).prefix(200).map { ["id": $0.id.uuidString, "title": String($0.title.prefix(512)), "url": String(($0.url?.absoluteString ?? "").prefix(8192))] },
            "bookmarks": bookmarks.dropFirst(librarySection == "bookmarks" ? offset : 0).prefix(40).map { ["id": $0.id.uuidString, "title": String($0.title.prefix(512)), "url": String($0.url.absoluteString.prefix(8192))] },
            "history": history.dropFirst(librarySection == "history" ? offset : 0).prefix(40).map { ["id": $0.id.uuidString, "title": String($0.title.prefix(512)), "url": String($0.url.absoluteString.prefix(8192))] },
            "notes": notes.dropFirst(librarySection == "notes" ? offset : 0).prefix(40).map { ["id": $0.id.uuidString, "title": String($0.title.prefix(100))] },
            "selectedNote": selectedNote.map { ["id": $0.id.uuidString, "title": String($0.title.prefix(100)), "text": String($0.text.prefix(200_000))] } as Any? ?? NSNull(),
            "libraryPage": libraryPage, "libraryCount": count,
            "account": ["connected": ChatGPTAccount.shared.connected, "busy": ChatGPTAccount.shared.busy, "status": ChatGPTAccount.shared.status ?? "", "models": ChatGPTAccount.shared.models],
            "notice": app.notice ?? "", "defaultStatus": defaultStatus, "imported": imported,
            "blinkAvailable": ChromiumRuntime.shared.isInstalled(in: app.dataDirectory),
            "assistantResponse": assistantResponse, "assistantBusy": assistantTask != nil,
            "updates": ["version": "Neutrino " + (update.current?.version ?? "development"), "automatic": update.automaticUpdates,
                        "message": update.message ?? "Updates are downloaded from GitHub. Your browsing data is kept.", "busy": update.busy, "pending": update.pending != nil],
            "modules": moduleSnapshot(), "moduleCatalogs": app.communityCatalogNames,
            "menuItems": encoded(app.declarativeDefinition(.menu)?.menu ?? []),
            "icons": app.declarativeDefinition(.icons)?.icons ?? [:],
            "iconImages": symbolImages(),
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
            snapshot["focusMode"] = model.focusMode
            snapshot["focusHidden"] = Array(model.focusHiddenComponents).sorted()
            let tab = model.activeWebTab
            snapshot["loading"] = tab.loading
            let visible = model.visibleEngineTabs
            snapshot["pageErrors"] = Dictionary(uniqueKeysWithValues: visible.compactMap { id, page in page.errorMessage.map { (id.uuidString, $0) } })
            if let error = tab.errorMessage { snapshot["pageError"] = error }
            snapshot["downloads"] = model.downloads.items.map { ["id": $0.id.uuidString, "name": $0.name, "status": $0.status, "complete": !$0.active && $0.destination != nil] as [String: Any] }
            // Only account identity is projected. Password values never enter the UI snapshot.
            snapshot["credentials"] = credentialMetadata
            let engines = visible.map(\.page)
            let identities = Set(engines.map(ObjectIdentifier.init))
            if observedEngines != identities {
                observedEngines = identities; engineObservations.removeAll()
                for engine in engines { engine.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in:&engineObservations) }
            }
            let document = model.session.selectedTabID.uuidString + ":" + tab.navigationRevision.uuidString
            if let responseDocument, responseDocument != document { assistantResponse = ""; self.responseDocument = nil }
            snapshot["assistantResponse"] = assistantResponse

        }
        if let center = downloadCenter {
            snapshot["downloads"] = center.items.map { ["id": $0.id.uuidString, "name": $0.name, "status": $0.status, "complete": !$0.active && $0.destination != nil] as [String: Any] }
        }
        var result = handle.dispatch(["op": "sync", "snapshot": snapshot])
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
        let needsResources = response["screen"] as? String == "resources" && model != nil && !app.terminating && !app.finalQuitDataFrozen
        if needsResources && (!resourcesOpen || resourceGeneration != app.resourceWorkerGeneration) {
            resourcesOpen = true; resourceGeneration = app.resourceWorkerGeneration
            do { let package = try app.resourceWorkerPackage(); try resourceWorker.start(executable: package.url, moduleID: package.id) }
            catch { resourceWorker.showFailure(error) }
        } else if !needsResources && resourcesOpen {
            resourcesOpen = false; resourceGeneration = nil; resourceWorker.stop()
        }
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
        if let token = response["focusToken"] as? Int, token != appliedFocusToken,
           let focus = response["focus"] as? String, !focus.isEmpty {
            appliedFocusToken = token
            container.window?.makeKey(); container.window?.makeFirstResponder(container.chrome)
        }
        if showingOverlay { container.hidePages() }
        return result
    }
    private func symbolImages() -> [String:String] {
        let symbols=app.declarativeDefinition(.icons)?.icons ?? [:]
        if symbols==cachedIconSymbols { return cachedIconImages }
        cachedIconSymbols=symbols;cachedIconImages=[:]
        // AppKit resolves validated SF Symbols. Rust still owns the controls and
        // layout; only transparent image masks cross this platform boundary.
        for (name,symbol) in symbols {
            guard let source=NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:18,weight:.regular)) else { continue }
            let image=NSImage(size:NSSize(width:24,height:24))
            image.lockFocus();source.draw(in:NSRect(x:2,y:2,width:20,height:20));image.unlockFocus()
            guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]),png.count<8000 else { continue }
            cachedIconImages[name]="data:image/png;base64,"+png.base64EncodedString()
        }
        return cachedIconImages
    }
    private func moduleSnapshot() -> [[String:Any]] {
        let catalogIDs = Set(app.catalog.map(\.id))
        let manifests = app.catalog + app.installedModules.filter { !catalogIDs.contains($0.id) }.map(\.manifest)
        return manifests.map { manifest in
            let installed = app.installedModules.first { $0.id == manifest.id }
            let current = installed?.manifest ?? manifest
            let provider = app.installedModules.first { $0.enabled && $0.manifest.capability == current.capability && $0.id != current.id }
            let values: [String:ModuleValue] = (try? app.repository?.settings(for: current.id)) ?? [:]
            let settings: [[String:Any]] = (current.settings ?? []).map { setting in
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
                    "dependencies":current.dependencies.map { id in app.catalog.first { $0.id == id }?.name ?? id },
                    "settings":settings] as [String:Any]
        }
    }
    private struct SpaceIdentity: Encodable { let id: UUID; let name: String; let profileID: UUID }
    private func push(_ response: [String: Any], interactive: Bool = false) {
        var result = response; result["passive"] = !interactive
        guard ready, !stopped, let data = try? JSONSerialization.data(withJSONObject: result), let json = String(data: data, encoding: .utf8) else { return }
        if result["overlay"] as? Bool == true { container.hidePages() }
        container.chrome.evaluateJavaScript("window.neutrino.receive(\(json))", completionHandler: nil)
    }
    private func sendAction(_ request: [String: Any]) {
        let result = handle.dispatch(request)
        if let commands = result["commands"] as? [[String: Any]], !commands.isEmpty { for command in commands { perform(command) }; push(synchronize(), interactive:true) }
        else { push(stamped(result), interactive:true) }
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
            let result = handle.dispatch(request)
            if result["overlay"] as? Bool == true { container.hidePages() }
            if let commands = result["commands"] as? [[String: Any]], !commands.isEmpty {
                for command in commands { perform(command) }
                replyHandler(synchronize(), nil)
            } else { replyHandler(stamped(result), nil) }
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
        guard !showingOverlay, let model, !model.isClosed, body["overlay"] as? Bool == false,
              let pages = body["pages"] as? [[String: Any]], pages.count <= 2 else { container.hidePages(); return }
        var visible = Set<UUID>()
        let allowed = model.session.split.map { Set([$0.first, $0.second]) } ?? Set([model.session.selectedTabID])
        for page in pages {
            guard let raw = page["id"] as? String, let id = UUID(uuidString: raw), allowed.contains(id),
                  model.session.tabs.contains(where: { $0.id == id && $0.url != nil }),
                  let x = page["x"] as? Double, let y = page["y"] as? Double,
                  let width = page["width"] as? Double, let height = page["height"] as? Double,
                  [x, y, width, height].allSatisfy(\.isFinite), width >= 1, height >= 1 else { continue }
            let rect = NSRect(x: x, y: y, width: width, height: height).intersection(container.bounds)
            guard !rect.isEmpty else { continue }
            let tab = model.webTab(id)
            let view = container.mounted[id] ?? EngineViewContainer(page: tab.nativeView)
            if view.superview !== container { container.addSubview(view) }
            view.mount(tab.nativeView); view.frame = rect; view.isHidden = false
            view.isPreviewing = body["editing"] as? Bool == true
            view.identifier = NSUserInterfaceItemIdentifier("neutrino.page")
            view.wantsLayer = true; view.layer?.cornerRadius = 10; view.layer?.masksToBounds = true
            container.mounted[id] = view; visible.insert(id)
        }
        for (id, view) in container.mounted where !visible.contains(id) { view.isHidden = true }
        for id in Array(container.mounted.keys) where !model.session.tabs.contains(where: { $0.id == id }) {
            if let view = container.mounted.removeValue(forKey: id) { view.unmount(); view.removeFromSuperview() }
        }
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
        if downloadCenter != nil && !["downloadCancel","downloadReveal","downloadOpen"].contains(operation) { return }
        let id = (command["id"] as? String).flatMap(UUID.init(uuidString:))
        let profileID = model?.session.profileID ?? app.library.profiles[0].id
        switch operation {
        case "navigate":
            if let value = command["url"] as? String { model?.navigate(value) }
        case "clearNotice": app.notice = nil
        case "newTab": model?.newTab()
        case "selectTab": if let id { model?.selectTab(id) }
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
        case "split": model?.beginSplit(.sideBySide)
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
        case "createFolder":
            if let name = command["name"] as? String { app.createFolder(name: name, spaceID: model?.session.spaceID) }
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
                for i in model.session.tabs.indices where model.session.tabs[i].folderID == id { model.session.tabs[i].folderID = nil }
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
        case "applyConfiguration":
            guard let object = command["configuration"], let data = try? JSONSerialization.data(withJSONObject: object),
                  var configuration = try? JSONDecoder().decode(Configuration.self, from: data) else { app.notice = "That appearance could not be saved."; return }
            configuration.normalize()
            app.applyConfiguration(configuration, to: command["space"] as? Bool == true ? model?.session.spaceID : nil)
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
            default: break
            }
        case "finishSetup": if let values = command["setup"] as? [String: Any] { finishSetup(values) }
        case "importBookmarks": imported = app.importBookmarks(profileID: profileID) || imported
        case "exportBookmarks": app.exportBookmarks(profileID: profileID)
        case "removeBookmark": if let id { app.library.bookmarks.removeAll { $0.id == id && $0.profileID == profileID } }
        case "clearHistory": app.library.history.removeAll { $0.profileID == profileID }
        case "restoreArchived":
            if let id, let space = model?.session.spaceID { app.restoreArchivedTab(id, spaceID: space); model?.selectTab(id) }
        case "defaultBrowser": setDefaultBrowser()
        case "checkUpdates": DistributionManager.shared.checkForUpdates(dataDirectory: app.dataDirectory)
        case "restartUpdate": DistributionManager.shared.requestRestart()
        case "cancelUpdate": DistributionManager.shared.cancel()
        case "newWindow": openWindow?(false)
        case "privateWindow": openWindow?(true)
        case "downloadCancel", "downloadReveal", "downloadOpen":
            guard let center = downloadCenter ?? model?.downloads, let item = center.items.first(where: { $0.id == id }) else { return }
            if operation == "downloadCancel" { center.cancel(item) }
            else if let url = item.destination, !item.active { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case "toggleModule":
            if let raw = command["id"] as? String, let module = app.installedModules.first(where: { $0.id == raw }) { app.toggleModule(module) }
        case "installModule":
            if let raw = command["id"] as? String, app.catalog.contains(where: { $0.id == raw }) { app.install(raw) }
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
        case "createNote":
            guard model?.isPrivate != true else { return }
            app.perform { selectedNoteID = try app.createModuleNote(profileID: profileID) }
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
        case "signIn": Task { @MainActor in await ChatGPTAccount.shared.signIn(); scheduleSync() }
        case "disconnectAI": Task { @MainActor in await ChatGPTAccount.shared.disconnect(); scheduleSync() }
        case "disableAI": app.library.preferences.ai = nil
        case "cancelAI": ChatGPTAccount.shared.cancelSignIn(); assistantGeneration = UUID(); assistantTask?.cancel(); assistantTask = nil
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
                    assistantResponse = content; sendAction(["op": "screen", "value": "reader"])
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
        default: app.notice = "This action is unavailable in the current browsing context."
        }
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
    private func finishSetup(_ values: [String: Any]) {
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
        var configuration = Configuration()
        configuration.theme.accent = (values["accent"] as? String).flatMap(Accent.init(rawValue:)) ?? .rose
        configuration.theme.colorMode = (values["appearance"] as? String).flatMap(ColorMode.init(rawValue:)) ?? .system
        configuration.layout.tabs = (values["layout"] as? String).flatMap(TabPlacement.init(rawValue:)) ?? .leading
        configuration.layout.tabsWidth = 240
        app.applyConfiguration(configuration)
        Task { @MainActor in
            app.library.preferences.completedOnboarding = true
            if !(await app.flush()) { app.library.preferences.completedOnboarding = false; app.notice = "Your setup could not be saved. Your choices are kept here; try again." }
            app.onboardingSaving = false
            scheduleSync()
        }
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
