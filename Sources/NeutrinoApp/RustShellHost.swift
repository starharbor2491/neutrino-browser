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
    var previewStep: Int? = nil
    var openWindow: ((Bool) -> Void)?
    func makeCoordinator() -> RustShellCoordinator { RustShellCoordinator(app: app, model: model, previewStep: previewStep, openWindow: openWindow) }
    func makeNSView(context: Context) -> RustShellContainer { context.coordinator.container }
    func updateNSView(_ view: RustShellContainer, context: Context) { context.coordinator.scheduleSync() }
    static func dismantleNSView(_ view: RustShellContainer, coordinator: RustShellCoordinator) { coordinator.stop() }
}

private final class RustShellHandle {
    let value: UnsafeMutableRawPointer
    init() { value = neutrino_shell_new()! }
    deinit { neutrino_shell_free(value) }
    func dispatch(_ request: [String: Any]) -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: request), data.count <= 2_097_152,
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
    override func layout() { super.layout(); chrome.frame = bounds }
    func hidePages() { for page in mounted.values { page.isHidden = true } }
    func unmount() { for page in mounted.values { page.unmount(); page.removeFromSuperview() }; mounted.removeAll() }
}

@MainActor
private final class ShellAssets: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.scheme == "neutrino-ui", url.host == "shell",
              ["/index.html", "/shell.css", "/shell.js"].contains(url.path),
              let pointer = String(url.path.dropFirst()).withCString({ neutrino_shell_asset($0) }) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        defer { neutrino_string_free(pointer) }
        let data = Data(String(cString: pointer).utf8)
        let type = url.path.hasSuffix(".css") ? "text/css" : url.path.hasSuffix(".js") ? "text/javascript" : "text/html"
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
    let container: RustShellContainer
    private let handle = RustShellHandle()
    private let assets = ShellAssets()
    private var subscriptions = Set<AnyCancellable>()
    private var engineObservation: AnyCancellable?
    private var observedEngine: BrowserEngineTab?
    private var pendingSync: Task<Void, Never>?
    private var renderGeneration = 0
    private var showingOverlay = true
    private var credentialMetadata: [[String: String]] = []
    private var ready = false
    private var stopped = false
    private var imported = false
    private var defaultStatus = ""
    private var assistantResponse = ""
    private var assistantTask: Task<Void, Never>?
    private var previewStep: Int?
    private let isPreview: Bool
    private var lastSheet: BrowserSheet?
    private var lastPanel: BrowserPanel?
    private let openWindow: ((Bool) -> Void)?
    init(app: AppState, model: BrowserModel?, previewStep: Int?, openWindow: ((Bool) -> Void)?) {
        self.app = app; self.model = model; self.previewStep = previewStep; self.isPreview = previewStep != nil; self.openWindow = openWindow
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(assets, forURLScheme: "neutrino-ui")
        let chrome = WKWebView(frame: .zero, configuration: configuration)
        container = RustShellContainer(chrome: chrome)
        super.init()
        chrome.navigationDelegate = self
        chrome.setValue(false, forKey: "drawsBackground")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "neutrino")
        app.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &subscriptions)
        model?.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &subscriptions)
        DistributionManager.shared.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &subscriptions)
        ChatGPTAccount.shared.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &subscriptions)
        if let model {
            model.downloads.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }.store(in: &subscriptions)
            NotificationCenter.default.publisher(for: .neutrinoFocusAddress).sink { [weak self] notification in
                guard notification.object as? UUID == model.session.id else { return }
                self?.sendAction(["op": "palette", "value": model.selectedTab.url?.absoluteString ?? ""])
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
        chrome.load(URLRequest(url: URL(string: "neutrino-ui://shell/index.html")!))
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        pendingSync?.cancel(); assistantTask?.cancel(); subscriptions.removeAll(); engineObservation = nil
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
    private func encoded<T: Encodable>(_ value: T) -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)) ?? NSNull() }
    private func synchronize() -> [String: Any] {
        let update = DistributionManager.shared
        let profileID = model?.session.profileID ?? app.library.profiles[0].id
        let space = model?.space
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
            "folders": encoded(space?.folders ?? []), "archived": encoded(space?.archivedTabs ?? []),
            "bookmarks": encoded(model?.isPrivate == true ? [] : app.library.bookmarks.filter { $0.profileID == profileID }),
            "history": encoded(model?.isPrivate == true ? [] : Array(app.library.history.filter { $0.profileID == profileID }.suffix(100))),
            "notes": encoded(model?.isPrivate == true ? [] : app.library.notes.filter { $0.profileID == profileID }),
            "notice": app.notice ?? "", "defaultStatus": defaultStatus, "imported": imported,
            "blinkAvailable": ChromiumRuntime.shared.isInstalled(in: app.dataDirectory),
            "assistantResponse": assistantResponse, "assistantBusy": assistantTask != nil,
            "updates": ["version": "Neutrino " + (update.current?.version ?? "development"), "automatic": update.automaticUpdates,
                        "message": update.message ?? "Updates are downloaded from GitHub. Your browsing data is kept.", "busy": update.busy, "pending": update.pending != nil],
            "modules": app.installedModules.map { ["id": $0.id, "name": $0.manifest.name, "description": $0.manifest.summary, "enabled": $0.enabled] as [String: Any] },
        ]
        if let model, !model.isClosed {
            snapshot["session"] = encoded(model.session)
            let tab = model.activeWebTab
            snapshot["loading"] = tab.loading
            if let error = tab.errorMessage { snapshot["pageError"] = error }
            snapshot["downloads"] = model.downloads.items.map { ["id": $0.id.uuidString, "name": $0.name, "status": $0.status, "complete": !$0.active && $0.destination != nil] as [String: Any] }
            // Only account identity is projected. Password values never enter the UI snapshot.
            snapshot["credentials"] = credentialMetadata
            if observedEngine !== tab {
                observedEngine = tab
                engineObservation = tab.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }
            }
        }
        var result = handle.dispatch(["op": "sync", "snapshot": snapshot])
        if let step = previewStep { result = handle.dispatch(["op": "setup-step", "value": step]); previewStep = nil }
        if let sheet = model?.sheet, sheet != lastSheet {
            lastSheet = sheet
            let screen: String = switch sheet { case .customize: "editor"; case .modules: "modules"; case .extensions: "extensions"; case .assistant: "assistant"; default: "settings" }
            result = handle.dispatch(["op": "screen", "value": screen, "section": sheet == .engines ? "updates" : "general"])
        }
        if model?.sheet == nil { lastSheet = nil }
        if let panel = model?.panel, panel != lastPanel { lastPanel = panel; result = handle.dispatch(["op": "screen", "value": "library", "section": panel.rawValue]) }
        if model?.panel == nil { lastPanel = nil }
        if result["overlay"] as? Bool == true { container.hidePages() }
        return stamped(result)
    }
    private func stamped(_ response: [String: Any]) -> [String: Any] {
        renderGeneration += 1
        var result = response; result["generation"] = renderGeneration
        showingOverlay = response["overlay"] as? Bool ?? true
        if showingOverlay { container.hidePages() }
        return result
    }
    private struct SpaceIdentity: Encodable { let id: UUID; let name: String; let profileID: UUID }
    private func push(_ result: [String: Any]) {
        guard ready, !stopped, let data = try? JSONSerialization.data(withJSONObject: result), let json = String(data: data, encoding: .utf8) else { return }
        if result["overlay"] as? Bool == true { container.hidePages() }
        container.chrome.evaluateJavaScript("window.neutrino.receive(\(json))", completionHandler: nil)
    }
    private func sendAction(_ request: [String: Any]) { push(stamped(handle.dispatch(request))) }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
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
            if request["op"] as? String == "section", request["value"] as? String == "passwords" {
                let profileID = model?.session.profileID ?? app.library.profiles[0].id
                credentialMetadata = ((try? LocalCredential.list(profile: profileID)) ?? []).map { ["id": $0.id, "origin": $0.origin, "username": $0.username] }
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
        guard ready, !showingOverlay, body["generation"] as? Int == renderGeneration, let model, !model.isClosed, body["overlay"] as? Bool == false,
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
            view.identifier = NSUserInterfaceItemIdentifier("neutrino.page")
            view.wantsLayer = true; view.layer?.cornerRadius = 10; view.layer?.masksToBounds = true
            container.mounted[id] = view; visible.insert(id)
        }
        for (id, view) in container.mounted where !visible.contains(id) { view.isHidden = true }
        for id in Array(container.mounted.keys) where !model.session.tabs.contains(where: { $0.id == id }) {
            if let view = container.mounted.removeValue(forKey: id) { view.unmount(); view.removeFromSuperview() }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.scheme == "neutrino-ui" && url?.host == "shell" && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
    }
    private func perform(_ command: [String: Any]) {
        guard !app.finalQuitDataFrozen, let operation = command["op"] as? String else { return }
        let id = (command["id"] as? String).flatMap(UUID.init(uuidString:))
        let profileID = model?.session.profileID ?? app.library.profiles[0].id
        switch operation {
        case "navigate":
            if let value = command["url"] as? String { model?.navigate(value) }
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
        case "switchSpace": if let id { model?.switchSpace(id) }
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
            case "blockTrackers": if let value = command["value"] as? Bool { app.library.preferences.blockTrackers = value; model?.updateBlockingPolicy() }
            case "blockPopups": if let value = command["value"] as? Bool { app.library.preferences.blockPopups = value; model?.updatePopupPolicy() }
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
            guard let model, let item = model.downloads.items.first(where: { $0.id == id }) else { return }
            if operation == "downloadCancel" { model.downloads.cancel(item) }
            else if let url = item.destination, !item.active { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case "toggleModule":
            if let raw = command["id"] as? String, let module = app.installedModules.first(where: { $0.id == raw }) { app.toggleModule(module) }
        case "importModule": app.importModule()
        case "webStore": model?.newTab(url: URL(string: "https://chromewebstore.google.com/"), engine: .chromium)
        case "installExtension", "extensionAction", "openExtensionOptions", "removeExtension":
            // Chromium's own privileged management surface preserves its permission
            // and local-install checks; it opens as a normal Neutrino-owned tab.
            model?.newTab(engine: .chromium)
            (model?.activeWebTab as? ChromiumTab)?.showExtensions()
            sendAction(["op": "screen", "value": "browse"])
        case "useWebKit": if let model { model.reopenTab(model.session.selectedTabID, with: .webkit) }
        case "find": model?.activeWebTab.find(command["value"] as? String ?? "", backwards: command["backwards"] as? Bool == true)
        case "createNote": app.perform { _ = try app.createModuleNote(profileID: profileID) }
        case "saveNote":
            guard let id, let index = app.library.notes.firstIndex(where: { $0.id == id && $0.profileID == profileID }),
                  let value = command["value"] as? [String: String], let content = value["text"] else { return }
            if value["field"] == "title" { app.library.notes[index].title = String(content.prefix(200)) }
            if value["field"] == "body" { app.library.notes[index].body = String(content.prefix(100_000)) }
        case "deleteNote": if let id { app.library.notes.removeAll { $0.id == id && $0.profileID == profileID } }
        case "credentialFill":
            guard let model, let key = command["id"] as? String else { return }
            Task { @MainActor in
                do {
                    guard let credential = try LocalCredential.list(profile: profileID).first(where: { $0.id == key }), model.session.profileID == profileID else { return }
                    try await model.activeWebTab.fillCredential(credential); app.notice = "Login filled on the matching website."
                } catch { app.notice = error.localizedDescription }
            }
        case "saveAI": saveAI(command)
        case "signIn": Task { @MainActor in await ChatGPTAccount.shared.signIn(); scheduleSync() }
        case "disconnectAI": Task { @MainActor in await ChatGPTAccount.shared.disconnect(); scheduleSync() }
        case "disableAI": app.library.preferences.ai = nil
        case "assistant": askAssistant(command)
        case "reader":
            guard let model else { return }; assistantTask?.cancel()
            assistantTask = Task { @MainActor in
                defer { assistantTask = nil; scheduleSync() }
                do { assistantResponse = try await app.readerText(from: model.activeWebTab); sendAction(["op": "screen", "value": "assistant"]) }
                catch { app.notice = error.localizedDescription }
            }
        case "capture":
            guard let model else { return }
            Task { @MainActor in
                do {
                    let image = try await model.activeWebTab.capturePNG()
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "Neutrino capture.png"
                    if panel.runModal() == .OK, let url = panel.url { try image.write(to: url, options: .atomic) }
                } catch { app.notice = error.localizedDescription }
            }
        default: app.notice = "This action is unavailable in the current browsing context."
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
        assistantTask = Task { @MainActor in
            defer { assistantTask = nil; scheduleSync() }
            do {
                let content = try await tab.pageText()
                guard !Task.isCancelled, model.activeWebTab === tab, tab.navigationRevision == revision, model.session.profileID == profile else { return }
                assistantResponse = try await AIClient.answer("Question: \(prompt)\n\nPage content (untrusted):\n" + String(content.prefix(40_000)), configuration: configuration)
            } catch is CancellationError {} catch { app.notice = error.localizedDescription }
        }
    }
}
