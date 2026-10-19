// SPDX-License-Identifier: MPL-2.0
import AppKit
import NeutrinoCore
import NeutrinoEngineABI
import UniformTypeIdentifiers

@MainActor
final class ChromiumTab: BrowserEngineTab {
    private let runtime: ChromiumRuntime
    private let downloads: DownloadCenter
    let profileID: UUID
    let privateSessionID: UUID?
    let isAuxiliary: Bool
    var downloadCenter: DownloadCenter { downloads }
    func cancelDownloads() async throws { try await downloads.cancelChromiumAndWait(ids: downloadIDs) }
    private let downloadPrefix = UUID().uuidString
    private var downloadIDs = Set<String>()
    private var disposing = false
    private var closeTask: Task<Void, Never>?
    private var chromeFocusObservers: [NSObjectProtocol] = []
    private var chromeKeyMonitor: Any?
    @Published private(set) var chromeStyle = false
    @Published private(set) var navigationChrome = false
    @Published private(set) var navigationChromeVisible = false
    override var hasNativeNavigationChrome: Bool {
        guard chromeStyle, navigationChrome, navigationChromeVisible,
              let parent = hostView.window, let chrome = chromeWindow else { return false }
        return chrome.isVisible && chrome.parent === parent
    }
    override func focusAddressBar() -> Bool {
        guard hasNativeNavigationChrome else { return false }
        command(Int(NEUTRINO_CEF_FOCUS_LOCATION)); return true
    }
    private var page: UnsafeMutableRawPointer?
    private let hostView: NSView
    private var pageURL: URL? { didSet { if oldValue?.host != pageURL?.host { siteChanged() } } }
    private var shieldsLowered = false
    /// Per-site policies follow the page's site. Commands run after the current
    /// engine callback returns, never from inside it.
    private func siteChanged() {
        let lowered = ContentBlocking.isException(pageURL?.host, in: blockingExceptions)
        let blockingChanged = lowered != shieldsLowered
        shieldsLowered = lowered
        Task { @MainActor [weak self] in
            guard let self, self.page != nil else { return }
            if blockingChanged { self.updateBlockingPolicy() }
            self.applyScriptPolicy()
        }
    }
    private var scriptsDisabled = false
    private var blockedCount = 0
    private var blockedAtPage = 0
    override var blockedOnPage: Int? { max(0, blockedCount - blockedAtPage) }
    override var blockedTotal: Int? { blockedCount }
    private var activePristine = true
    private var failedURL: URL?
    private var pageTitle: String?
    private var restoringPages = false
    private var sessionPages: [ChromiumSessionPage] = []
    private(set) var interfacePages: [[String:Any]] = []
    var noteSourcePages: [[String:Any]] {
        interfacePages.compactMap { item in
            guard let id=item["id"] as? Int,id>0,let address=item["url"] as? String,
                  let url=URL(string:address),AddressResolver.isWebURL(url) else{return nil}
            return ["id":id,"url":address,"token":"\(runtime.sourceProcessID.uuidString):\(id)"]
        }
    }
    var selectedSourcePageToken: String? {
        guard let id=interfacePages.first(where:{$0["selected"] as? Bool == true})?["id"] as? Int else{return nil}
        return noteSourcePages.first(where:{$0["id"] as? Int == id})?["token"] as? String
    }
    func selectInterfacePage(_ id: Int, close: Bool = false) {
        guard interfacePages.contains(where: { $0["id"] as? Int == id }) else { return }
        command(Int(close ? NEUTRINO_CEF_CLOSE_INNER_PAGE : NEUTRINO_CEF_SELECT_INNER_PAGE),value:Double(id))
    }
    private var nextRequest = 1
    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, any Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int: PendingRequest] = [:]
    private var readerContexts: [Int: String] = [:]
    override var nativeView: NSView { hostView }
    var chromeWindow: NSWindow? { hostView.value(forKey: "browserWindow") as? NSWindow }
    override func setInterfaceEditing(_ value: Bool, owner: UUID) {
        super.setInterfaceEditing(value, owner: owner)
        command(Int(NEUTRINO_CEF_SUSPEND_INPUT), value: interfaceEditing ? 1 : 0)
    }
    override var url: URL? { activeContentKnown ? failedURL ?? pageURL : nil }
    override var title: String? { activeContentKnown ? pageTitle : nil }
    override var isShowingStartPage: Bool { !restoringPages && activeContentKnown && activePristine }
    private var activeContentKnown: Bool { hostView.value(forKey: "activeContentKnown") as? Bool == true }
    private var refreshingActiveContent = false
    override func refreshActiveContent() {
        guard !refreshingActiveContent, !restoringPages else { return }
        refreshingActiveContent = true
        defer { refreshingActiveContent = false }
        command(Int(NEUTRINO_CEF_SYNC_ACTIVE))
    }
    var isReadyForEngineSwitch: Bool { !restoringPages && activeContentKnown }
    override var chromiumSessionPages: [ChromiumSessionPage]? {
        restoringPages || !activeContentKnown || sessionPages.isEmpty ? nil : sessionPages
    }
    override func restoreChromiumSessionPages(_ pages: [ChromiumSessionPage]) {
        let addresses = ChromiumSessionPage.normalized(pages).map { $0.url?.absoluteString ?? "" }
        guard !addresses.isEmpty, let data = try? JSONSerialization.data(withJSONObject:addresses), let text = String(data:data,encoding:.utf8) else { return }
        command(Int(NEUTRINO_CEF_RESTORE_TABS),text:text)
    }
    override var engineID: BrowserEngineID { .chromium }

    init(runtime: ChromiumRuntime, page: UnsafeMutableRawPointer, downloads: DownloadCenter, profileID: UUID, privateSessionID: UUID?) {
        self.runtime = runtime; self.page = page; self.downloads = downloads
        self.profileID = profileID; self.privateSessionID = privateSessionID
        hostView = Unmanaged<NSView>.fromOpaque(runtime.api!.native_view(page)!).takeUnretainedValue()
        isAuxiliary = hostView.value(forKey: "auxiliary") as? Bool == true
        super.init()
        chromeStyle = hostView.value(forKey: "chromeStyle") as? Bool == true
        navigationChrome = hostView.value(forKey: "navigationChrome") as? Bool == true
        runtime.register(self)
        runtime.api!.set_callbacks(page, Unmanaged.passUnretained(self).toOpaque(), { context, event, json in
            guard let context, let json else { return }
            MainActor.assumeIsolated {
                Unmanaged<ChromiumTab>.fromOpaque(context).takeUnretainedValue().receive(event, json: String(cString: json))
            }
        }, { context, child, url in
            guard let context, let child else { return 0 }
            return MainActor.assumeIsolated {
                let parent = Unmanaged<ChromiumTab>.fromOpaque(context).takeUnretainedValue()
                // A download can keep the native source alive after its Neutrino
                // owner closes. Reject before constructing a Swift child; the
                // native callback contract owns destruction of rejected pages.
                guard !parent.disposing,
                      parent.runtime.canAdoptPage(profileID: parent.profileID, privateSessionID: parent.privateSessionID) else { return 0 }
                let tab = ChromiumTab(runtime: parent.runtime, page: child, downloads: parent.downloads, profileID: parent.profileID, privateSessionID: parent.privateSessionID)
                if tab.isAuxiliary {
                    tab.onNotice = parent.onNotice
                    tab.onBrowserCommand = { [weak tab] command in
                        switch command {
                        case "quit": NSApp.terminate(nil)
                        case "closeTab", "closeWindow": tab?.dispose()
                        case "newWindow": ChromiumTab.performApplicationMenuItem("New window")
                        case "privateWindow": ChromiumTab.performApplicationMenuItem("New private window")
                        case "downloads": tab?.downloads.showWindow()
                        default: break
                        }
                    }
                    tab.allowPopups = parent.allowPopups
                    tab.blockingEnabled = parent.blockingEnabled
                    tab.updatePopupPolicy()
                    return 1
                }
                let target = url.flatMap { URL(string: String(cString: $0)) }
                let accepted = parent.onCreateWindow?(tab, target) == true
                if !accepted { tab.dispose() }
                return accepted ? 1 : 0
            }
        })
        // AppKit can change an attached child's key status without a distinct
        // Views activation transition. Use the actual owned NSWindow event to
        // keep Neutrino's selected split pane and native commands synchronized.
        chromeFocusObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                let windowID = ObjectIdentifier(window)
                let becameKey = notification.name == NSWindow.didBecomeKeyNotification
                MainActor.assumeIsolated {
                    guard let self, let chrome = self.chromeWindow,
                          windowID == ObjectIdentifier(chrome) else { return }
                    self.runtime.objectWillChange.send()
                    guard becameKey else { return }
                    if self.interfaceEditing { self.hostView.window?.makeKey(); return }
                    if let owner = self.hostView.window, owner.isVisible, owner.canBecomeMain {
                        owner.makeMain()
                    }
                    self.onActivate?()
                }
            }
        }
        // An intact Chrome child is a separate key window, outside SwiftUI's
        // focused-scene responder chain. Route Neutrino's tab shortcuts and the
        // visible Chrome omnibox before the parent menu can consume them.
        chromeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let windowID = event.window.map(ObjectIdentifier.init)
            let key = event.charactersIgnoringModifiers?.lowercased()
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control]).rawValue
            let handled = MainActor.assumeIsolated {
                guard let self, !self.isAuxiliary,
                      let chrome = self.chromeWindow, windowID == ObjectIdentifier(chrome), chrome.isKeyWindow else { return false }
                if self.runtime.finalQuitFrozen || self.interfaceEditing { return true }
                if !self.hasNativeNavigationChrome {
                    let command: String
                    if modifiers == NSEvent.ModifierFlags.command.rawValue, key == "l" { command = "focusAddress" }
                    else if modifiers == NSEvent.ModifierFlags.command.rawValue, key == "k" { command = "quickNavigation" }
                    else if modifiers == NSEvent.ModifierFlags.command.rawValue, key == "t" { command = "newTab" }
                    else if modifiers == NSEvent.ModifierFlags.command.rawValue, key == "w" { command = "closeTab" }
                    else if modifiers == NSEvent.ModifierFlags.command.union(.shift).rawValue, key == "t" { command = "reopenTab" }
                    else if modifiers == NSEvent.ModifierFlags.command.union(.shift).rawValue, key == "w" { command = "closeWindow" }
                    else if modifiers == NSEvent.ModifierFlags.command.union(.shift).rawValue, key == "[" || key == "{" { command = "previousTab" }
                    else if modifiers == NSEvent.ModifierFlags.command.union(.shift).rawValue, key == "]" || key == "}" { command = "nextTab" }
                    else { return false }
                    self.onActivate?(); self.onBrowserCommand?(command); return true
                }
                if modifiers == NSEvent.ModifierFlags.command.rawValue, key == "l" {
                    self.onActivate?()
                    return self.focusAddressBar()
                }
                if modifiers == NSEvent.ModifierFlags.command.union(.shift).rawValue, key == "w" {
                    self.onActivate?(); self.onBrowserCommand?("closeWindow"); return true
                }
                let nativeCommand: NativeTabCommand
                if modifiers == NSEvent.ModifierFlags.command.rawValue, key == "t" { nativeCommand = .new }
                else if modifiers == NSEvent.ModifierFlags.command.rawValue, key == "w" { nativeCommand = .close }
                else if modifiers == NSEvent.ModifierFlags.command.union(.shift).rawValue, key == "t" { nativeCommand = .reopen }
                else if modifiers == NSEvent.ModifierFlags.command.union(.shift).rawValue, key == "[" || key == "{" { nativeCommand = .previous }
                else if modifiers == NSEvent.ModifierFlags.command.union(.shift).rawValue, key == "]" || key == "}" { nativeCommand = .next }
                else { return false }
                self.onActivate?()
                return self.performNativeTabCommand(nativeCommand)
            }
            return handled ? nil : event
        }
    }
    private static func performApplicationMenuItem(_ title: String) {
        func perform(in menu: NSMenu) -> Bool {
            for (index, item) in menu.items.enumerated() {
                if item.title == title, item.isEnabled { menu.performActionForItem(at: index); return true }
                if let submenu = item.submenu, perform(in: submenu) { return true }
            }
            return false
        }
        // Dispatch the app's existing File command, which remains available
        // after the originating SwiftUI browser window has closed.
        if let menu = NSApp.mainMenu { _ = perform(in: menu) }
    }
    private func command(_ command: Int, text: String = "", value: Double = 0) {
        guard let page, let api = runtime.api else { return }
        text.withCString { api.command(page, Int32(command), $0, value) }
    }
    override func load(_ url: URL) {
        guard AddressResolver.isWebURL(url) else { errorMessage = "Only HTTP and HTTPS addresses are supported."; return }
        failedURL = nil; activePristine = false
        errorMessage = nil; pageURL = url; loading = true
        command(Int(NEUTRINO_CEF_LOAD), text: url.absoluteString)
    }
    override func updateBlockingPolicy() {
        // Chromium filters per browser group, so a site with Shields down turns
        // blocking off for this tab while it shows that site.
        let enabled = blockingEnabled && !ContentBlocking.isException(pageURL?.host, in: blockingExceptions)
        command(Int(NEUTRINO_CEF_SET_BLOCKING), text: ContentBlocking.domains(ads: blockAds, custom: blockingCustom, subscribed: blockingSubscribed).joined(separator: "\n"), value: enabled ? 1 : 0)
    }
    /// The isolated world page tools use for the current document, created once per document.
    private var toolWorld: (revision: UUID, unique: String)?
    private func evaluateIsolated(_ expression: String, userGesture: Bool = false, wait: Duration? = nil) async throws -> Any {
        let revision = navigationRevision
        guard !loading else { throw ValidationError("The page is still loading. Try again in a moment.") }
        let unique: String
        if let world = toolWorld, world.revision == revision, readerContexts.values.contains(world.unique) {
            unique = world.unique
        } else {
            _ = try await request("Runtime.enable",parameters:[:])
            let tree = try await request("Page.getFrameTree", parameters: [:])
            guard let body = try JSONSerialization.jsonObject(with: tree) as? [String: Any], let frameTree = body["frameTree"] as? [String: Any], let frame = frameTree["frame"] as? [String: Any], let frameID = frame["id"] as? String else { throw ValidationError("The page is unavailable.") }
            let world = try await request("Page.createIsolatedWorld", parameters: ["frameId": frameID, "worldName": "org.neutrino.reader"])
            guard navigationRevision == revision, let value = try JSONSerialization.jsonObject(with: world) as? [String: Any], let contextID = value["executionContextId"] as? Int, let created = readerContexts[contextID] else { throw ValidationError("The page changed. Try again.") }
            unique = created; toolWorld = (revision, created)
        }
        let result = try await request("Runtime.evaluate", parameters: ["expression": expression, "returnByValue": true, "uniqueContextId": unique, "timeout": 5000, "userGesture": userGesture, "awaitPromise": wait != nil], timeout: wait ?? .seconds(15))
        guard navigationRevision == revision, let response = try JSONSerialization.jsonObject(with: result) as? [String: Any], response["exceptionDetails"] == nil, let object = response["result"] as? [String: Any] else { throw ValidationError("The page could not complete this request.") }
        return object["value"] ?? ""
    }
    override func pageText() async throws -> String { try await evaluateIsolated("(document.body?.innerText ?? '').slice(0, 40000)") as? String ?? "" }
    override func selectedText() async throws -> String { try await evaluateIsolated("(window.getSelection()?.toString() ?? '').slice(0, 8000)") as? String ?? "" }
    override func fillCredential(_ credential: LocalCredential) async throws { _ = try await evaluateIsolated("(() => { " + credential.autofillScript + " })()") }
    override func fillCredentialOnUse(_ credential: LocalCredential) async throws { _ = try await evaluateIsolated("(() => { " + credential.autofillOnUseScript + " })()") }
    override func runPageScript(_ source: String, userGesture: Bool = false, wait: Duration? = nil) async throws -> String {
        try await evaluateIsolated(source, userGesture: userGesture, wait: wait) as? String ?? ""
    }
    /// Chromium mutes the whole page, Web Audio included.
    override func setMuted(_ value: Bool) { command(Int(NEUTRINO_CEF_MUTE), value: value ? 1 : 0) }
    private func chromeCommand(_ name: String) { command(Int(NEUTRINO_CEF_CHROME_COMMAND), text: name) }
    override func printPage() { chromeCommand("IDC_PRINT") }
    override func showDeveloperTools() { chromeCommand("IDC_DEV_TOOLS") }
    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ValidationError("Chromium returned an unexpected response.") }
        return value
    }
    override func pagePDF() async throws -> Data {
        let result = try object(try await request("Page.printToPDF", parameters: ["printBackground": true, "preferCSSPageSize": true], timeout: .seconds(30)))
        guard let encoded = result["data"] as? String, encoded.utf8.count <= 90 * 1024 * 1024, let pdf = Data(base64Encoded: encoded) else {
            throw ValidationError("Chromium could not save this page as a PDF.")
        }
        return pdf
    }
    override func fullPageCapture() async throws -> (data: Data, type: String) {
        let metrics = try object(try await request("Page.getLayoutMetrics", parameters: [:]))
        let size = (metrics["cssContentSize"] ?? metrics["contentSize"]) as? [String: Any]
        let width = min(8192, max(1, size?["width"] as? Double ?? 1280)), height = min(16384, max(1, size?["height"] as? Double ?? 800))
        let result = try object(try await request("Page.captureScreenshot", parameters: ["format": "png", "captureBeyondViewport": true,
            "clip": ["x": 0, "y": 0, "width": width, "height": height, "scale": 1]], timeout: .seconds(30)))
        guard let encoded = result["data"] as? String, encoded.utf8.count <= 90 * 1024 * 1024, let image = Data(base64Encoded: encoded),
              image.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw ValidationError("Chromium could not capture the full page.") }
        return (image, "png")
    }
    override func navigationEntries(back: Bool) async -> [[String: Any]] {
        guard let history = try? object(try await request("Page.getNavigationHistory", parameters: [:])),
              let current = history["currentIndex"] as? Int, let entries = history["entries"] as? [[String: Any]] else { return [] }
        let indices = back ? Array(stride(from: current - 1, through: max(0, current - 15), by: -1)) : Array((current + 1)..<min(entries.count, current + 16))
        return indices.compactMap { index in
            guard entries.indices.contains(index), let url = entries[index]["url"] as? String, url.hasPrefix("http") else { return nil }
            return ["offset": index - current, "title": entries[index]["title"] as? String ?? "", "url": url]
        }
    }
    override func goToHistory(offset: Int) {
        Task { @MainActor [weak self] in
            guard let self, let history = try? self.object(try await self.request("Page.getNavigationHistory", parameters: [:])),
                  let current = history["currentIndex"] as? Int, let entries = history["entries"] as? [[String: Any]],
                  entries.indices.contains(current + offset), let id = entries[current + offset]["id"] as? Int else { return }
            _ = try? await self.request("Page.navigateToHistoryEntry", parameters: ["entryId": id])
        }
    }
    override func applyScriptPolicy() {
        guard let site = ContentBlocking.site(pageURL) else { return }
        let blocked = scriptsBlocked?(site) == true
        guard blocked != scriptsDisabled else { return }
        scriptsDisabled = blocked
        Task { @MainActor [weak self] in
            // The setting applies from the next document; reload so this page follows it.
            _ = try? await self?.request("Emulation.setScriptExecutionDisabled", parameters: ["value": blocked])
            self?.reload()
        }
    }
    override func setNetworkLimit(bytesPerSecond: Int) {
        Task { @MainActor [weak self] in
            _ = try? await self?.request("Network.enable", parameters: [:])
            let rate = bytesPerSecond > 0 ? bytesPerSecond : -1
            _ = try? await self?.request("Network.emulateNetworkConditions", parameters: ["offline": false, "latency": 0, "downloadThroughput": rate, "uploadThroughput": rate])
        }
    }
    /// Profile preferences wait until this tab's page has finished loading, so
    /// they never reach the engine while it is still creating the browser.
    private var privacy: (httpsOnly: Bool, cookies: Bool, localIP: Bool)?
    override func setPrivacyPreferences(httpsOnly: Bool, blockThirdPartyCookies: Bool, hideLocalIP: Bool) {
        privacy = (httpsOnly, blockThirdPartyCookies, hideLocalIP)
        if activeContentKnown && !loading { sendPrivacyPreferences() }
    }
    private var credentialCaptureWanted = false, credentialCaptureInstalled = false
    override func installCredentialCapture() { credentialCaptureWanted = true; if activeContentKnown && !loading { installCredentialBinding() } }
    /// A binding that only Neutrino's own isolated world can call reports sign-ins.
    private func installCredentialBinding() {
        guard credentialCaptureWanted, !credentialCaptureInstalled, let source = PageScript.source("credentialCapture") else { return }
        credentialCaptureInstalled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.request("Runtime.enable", parameters: [:])
                _ = try await self.request("Runtime.addBinding", parameters: ["name": "neutrinoCredential", "executionContextName": "org.neutrino.passwords"])
                _ = try await self.request("Page.addScriptToEvaluateOnNewDocument", parameters: ["source": source, "worldName": "org.neutrino.passwords", "runImmediately": true])
            } catch { self.credentialCaptureInstalled = false }
        }
    }
    private func sendPrivacyPreferences() {
        guard let privacy else { return }
        self.privacy = nil
        command(Int(NEUTRINO_CEF_PREFERENCE), text: "https_only_mode_enabled", value: privacy.httpsOnly ? 1 : 0)
        command(Int(NEUTRINO_CEF_PREFERENCE), text: "profile.cookie_controls_mode", value: privacy.cookies ? 1 : 0)
        command(Int(NEUTRINO_CEF_PREFERENCE), text: "webrtc.ip_handling_policy", value: privacy.localIP ? 1 : 0)
    }
    /// Cookies and cached files of this tab's Chromium profile, for all time.
    override func clearWebsiteData(cookies: Bool, cache: Bool, hosts: [String] = []) async {
        if cookies {
            // Chromium's DevTools clears local storage, IndexedDB and service workers per origin.
            var sites = Set(await cookieDomains())
            for host in hosts { sites.insert(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) }
            let list = Array(sites.sorted().prefix(300))
            for start in stride(from: 0, to: list.count, by: 20) {
                await withTaskGroup(of: Void.self) { group in
                    for host in list[start..<min(start + 20, list.count)] { group.addTask { await self.clearSiteData(host: host) } }
                }
            }
            _ = try? await request("Network.clearBrowserCookies", parameters: [:])
        }
        if cache { _ = try? await request("Network.clearBrowserCache", parameters: [:]) }
    }
    override func clearSiteData(host: String) async {
        for origin in ["https://" + host, "https://www." + host, "http://" + host] {
            _ = try? await request("Storage.clearDataForOrigin", parameters: ["origin": origin, "storageTypes": "all"])
        }
    }
    override func cookieDomains() async -> [String] {
        guard let result = try? object(try await request("Storage.getCookies", parameters: [:])),
              let cookies = result["cookies"] as? [[String: Any]] else { return [] }
        var domains = Set<String>()
        for cookie in cookies.prefix(5000) {
            guard var domain = cookie["domain"] as? String else { continue }
            if domain.hasPrefix(".") { domain.removeFirst() }
            if domain.hasPrefix("www.") { domain.removeFirst(4) }
            domains.insert(domain)
        }
        return Array(domains).sorted()
    }
    override func resourceUsage() async -> (memoryMB: Double, cpuSeconds: Double)? {
        _ = try? await request("Performance.enable", parameters: [:], timeout: .seconds(3))
        guard let result = try? object(try await request("Performance.getMetrics", parameters: [:], timeout: .seconds(3))),
              let metrics = result["metrics"] as? [[String: Any]] else { return nil }
        let value = { (name: String) in metrics.first { $0["name"] as? String == name }?["value"] as? Double ?? 0 }
        return (value("JSHeapTotalSize") / 1_048_576, value("TaskDuration"))
    }
    override func performNativeTabCommand(_ command: NativeTabCommand) -> Bool {
        guard !disposing, let page, let api = runtime.api,
              hasNativeNavigationChrome || (isAuxiliary && chromeWindow?.isVisible == true) else { return false }
        if runtime.finalQuitFrozen { return true }
        let native: Int
        switch command {
        case .new: native = Int(NEUTRINO_CEF_NEW_TAB)
        case .close: native = Int(NEUTRINO_CEF_CLOSE_TAB)
        case .reopen: native = Int(NEUTRINO_CEF_REOPEN_TAB)
        case .previous: native = Int(NEUTRINO_CEF_PREVIOUS_TAB)
        case .next: native = Int(NEUTRINO_CEF_NEXT_TAB)
        }
        if api.native_tab_command(page, Int32(native)) == 0 {
            onNotice?("This Chrome tab action is not available yet.")
        }
        // This visible native Chrome window owns the command even while Chrome
        // disables it. Never fall through to an unrelated outer Neutrino tab.
        return true
    }
    override func showStartPage() {
        failedURL = nil; errorMessage = nil; didStartNavigation()
        activePristine = true; pageURL = nil; pageTitle = "New tab"; loading = false
        command(Int(NEUTRINO_CEF_HOME))
    }
    func showExtensions() { failedURL = nil; activePristine = false; command(Int(NEUTRINO_CEF_EXTENSIONS)) }
    override func reload() {
        // Provisional failures do not commit a new CEF document. Retry the
        // reported web address instead of reloading the previous Home entry.
        if let failedURL { load(failedURL) }
        else { errorMessage = nil; command(Int(NEUTRINO_CEF_RELOAD)) }
    }
    override func stop() { command(Int(NEUTRINO_CEF_STOP)) }
    override func goBack() { failedURL = nil; errorMessage = nil; command(Int(NEUTRINO_CEF_BACK)) }
    override func goForward() { failedURL = nil; errorMessage = nil; command(Int(NEUTRINO_CEF_FORWARD)) }
    override func setZoom(_ value: Double) {
        guard value.isFinite, !disposing, !restoringPages else { return }
        refreshActiveContent()
        guard activeContentKnown else { return }
        zoom = min(5, max(0.25, value))
        command(Int(NEUTRINO_CEF_ZOOM), value: zoom)
    }
    override func updatePopupPolicy() { command(Int(NEUTRINO_CEF_POPUPS), value: allowPopups?() == true ? 1 : 0) }
    override func focus() {
        guard !interfaceEditing else { return }
        command(Int(NEUTRINO_CEF_FOCUS))
        // Re-selecting the native pane while this child is already key emits
        // no AppKit key-window notification, but still changes command context.
        if chromeWindow?.isKeyWindow == true { onActivate?() }
    }
    override func find(_ text: String, backwards: Bool = false) { command(Int(NEUTRINO_CEF_FIND), text: text, value: backwards ? 1 : 0) }
    override func pageHTML() async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        func remaining() throws -> Duration {
            let duration = clock.now.duration(to: deadline)
            guard duration > .zero else { throw ValidationError("Chromium did not capture the page before the snapshot timed out.") }
            return duration
        }
        _ = try await request("Runtime.enable", parameters: [:], timeout: remaining())
        let treeData = try await request("Page.getFrameTree", parameters: [:], timeout: remaining())
        guard let tree = try JSONSerialization.jsonObject(with: treeData) as? [String: Any],
              let frameTree = tree["frameTree"] as? [String: Any],
              let frame = frameTree["frame"] as? [String: Any], let frameID = frame["id"] as? String else {
            throw ValidationError("Chromium could not find the page to capture.")
        }
        // Page JavaScript cannot replace this world's native XMLSerializer or
        // document accessors. No cross-origin access is granted to the world.
        let worldData = try await request("Page.createIsolatedWorld", parameters: ["frameId": frameID, "worldName": "org.neutrino.reader"], timeout: remaining())
        guard let world = try JSONSerialization.jsonObject(with: worldData) as? [String: Any],
              let contextID = world["executionContextId"] as? Int,
              let uniqueContextID = readerContexts[contextID] else {
            throw ValidationError("Chromium could not isolate the page snapshot.")
        }
        let expression = "(() => { const html = document.documentElement ? new XMLSerializer().serializeToString(document.documentElement) : ''; if (html.length > 1048576) throw new Error('Page snapshot exceeds 1 MB.'); return html; })()"
        let budget = try remaining()
        let components = budget.components
        let milliseconds = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        // Numeric context IDs can be reused after a process-changing navigation.
        // A vanished unique context fails safely instead of evaluating page code.
        let data = try await request("Runtime.evaluate", parameters: ["expression": expression, "returnByValue": true, "uniqueContextId": uniqueContextID, "timeout": milliseconds], timeout: budget)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = response["result"] as? [String: Any], let html = result["value"] as? String,
              html.utf8.count <= ReaderRequest.maximumHTMLBytes else {
            throw ValidationError("Chromium could not capture this page within the 1 MB snapshot limit.")
        }
        return html
    }
    override func capturePNG() async throws -> Data {
        let data = try await request("Page.captureScreenshot", parameters: ["format": "png", "captureBeyondViewport": false])
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoded = result["data"] as? String, encoded.utf8.count <= 45 * 1024 * 1024,
              let image = Data(base64Encoded: encoded), image.count <= 32 * 1024 * 1024,
              image.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw ValidationError("Chromium returned an invalid or oversized page capture.")
        }
        return image
    }
    /// Internal DevTools transport, never a listening debugging port.
    func request(_ method: String, parameters: [String: Any], timeout: Duration = .seconds(15), file: StaticString = #fileID, line: UInt = #line) async throws -> Data {
        try Task.checkCancellation()
        guard !restoringPages else { throw ValidationError("This Chromium pane is still restoring its saved tabs.") }
        command(Int(NEUTRINO_CEF_SYNC_ACTIVE))
        guard let page, let api = runtime.api else { throw ValidationError("This Chromium page is closed.") }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: parameters), as: UTF8.self)
        let id = nextRequest; nextRequest += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    if CommandLine.arguments.contains("--smoke-test"), ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_DATA"] != nil {
                        print("Neutrino Chromium request timed out: method=\(method), id=\(id), source=\(file):\(line), loading=\(self?.loading == true), mounted=\(self?.nativeView.window != nil)")
                    }
                    self?.completeRequest(id, result: .failure(ValidationError("Chromium did not respond before the request timed out.")))
                }
                pending[id] = PendingRequest(continuation: continuation, timeout: timer)
                method.withCString { method in json.withCString { api.devtools(page, Int32(id), method, $0) } }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.completeRequest(id, result: .failure(CancellationError())) }
        }
    }
    private func completeRequest(_ id: Int, result: Result<Data, any Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }
    private func receive(_ event: Int32, json: String) {
        guard let data = json.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if CommandLine.arguments.contains("--smoke-test"), ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_DATA"] != nil,
           event == Int32(NEUTRINO_CEF_ERROR) || value["committedURL"] != nil {
            print("Neutrino Chromium navigation event=\(event) known=\(activeContentKnown) committed=\(value["committedURL"] as? String ?? "nil") failed=\(value["failedURL"] as? String ?? "nil") error=\(value["message"] as? String ?? "nil")")
        }
        switch event {
        case Int32(NEUTRINO_CEF_STATE), Int32(NEUTRINO_CEF_FINISHED):
            if value["activeContentChanged"] as? Bool == true {
                cancelRequests(); didStartNavigation(); failedURL = nil; errorMessage = nil; pageURL = nil; pageTitle = nil
            }
            if let pristine = value["pristine"] as? Bool { activePristine = pristine }
            if let restoring = value["restoring"] as? Bool { restoringPages = restoring }
            if let pages = value["innerPages"] as? [[String: Any]], pages.count <= 200 {
                let ordered = pages.filter { $0["selected"] as? Bool == true } + pages.filter { $0["selected"] as? Bool != true }
                interfacePages = ordered.map { item in
                    ["id":item["id"] as? Int ?? 0,"title":boundedPageTitle(item["title"] as? String ?? "Page"),"url":item["url"] as? String ?? "","selected":item["selected"] as? Bool ?? false]
                }
                sessionPages = ordered.map { item in
                    let candidate = (item["url"] as? String).flatMap(URL.init(string:))
                    let url = candidate.flatMap { AddressResolver.isWebURL($0) && $0.absoluteString.utf8.count <= 8192 ? $0 : nil }
                    let title = url == nil ? "New tab" : boundedPageTitle(item["title"] as? String ?? "Untitled")
                    return ChromiumSessionPage(url:url,title:title)
                }
            }
            if let chrome = value["chromeStyle"] as? Bool { chromeStyle = chrome }
            if let chrome = value["navigationChrome"] as? Bool { navigationChrome = chrome }
            if let visible = value["navigationChromeVisible"] as? Bool { navigationChromeVisible = visible }
            if let blocked = value["blocked"] as? Int, blocked >= 0 { blockedCount = blocked }
            if value["navigationStart"] as? Bool == true { blockedAtPage = blockedCount }
            if let address = value["committedURL"] as? String, let url = URL(string: address) {
                failedURL = nil; errorMessage = nil; activePristine = false; pageURL = url; pageTitle = nil
            }
            if value["navigationStart"] as? Bool == true {
                didStartNavigation()
                if value["committedURL"] != nil { onChange?(false) }
                return
            }
            if let address = value["url"] as? String { pageURL = URL(string: address) }
            if let title = value["title"] as? String { pageTitle = title.isEmpty ? nil : boundedPageTitle(title) }
            if let value = value["loading"] as? Bool {
                loading = value; progress = value ? 0.4 : 1
                if value && failedURL == nil { errorMessage = nil }
            }
            if let value = value["canGoBack"] as? Bool { canGoBack = value }
            if let value = value["canGoForward"] as? Bool { canGoForward = value }
            if let value = value["zoom"] as? Double, value.isFinite, value > 0, zoom != value { zoom = value }
            onChange?(event == Int32(NEUTRINO_CEF_FINISHED))
            if event == Int32(NEUTRINO_CEF_FINISHED) {
                let revision = navigationRevision
                Task { @MainActor [weak self] in
                    guard let self, self.page != nil, self.navigationRevision == revision, !self.loading else { return }
                    self.sendPrivacyPreferences()
                    self.installCredentialBinding()
                    self.onPageLoaded?()
                }
            }
        case Int32(NEUTRINO_CEF_ERROR):
            errorMessage = value["message"] as? String
            loading = false; progress = 0
            if let address = value["failedURL"] as? String, let url = URL(string: address), AddressResolver.isWebURL(url) {
                activePristine = false; failedURL = url; pageTitle = nil
            }
            onChange?(false)
        case Int32(NEUTRINO_CEF_NOTICE):
            if let message = value["message"] as? String { onNotice?(message) }
        case Int32(NEUTRINO_CEF_CLOSED):
            removeFocusObserver()
            downloads.chromiumOwnerClosed(ids: downloadIDs)
            downloadIDs.removeAll()
            page = nil; cancelRequests(); runtime.finishedClosing(self); onClose?()
        case Int32(NEUTRINO_CEF_ACTIVATE):
            onActivate?()
        case Int32(NEUTRINO_CEF_BROWSER_COMMAND):
            if let command = value["message"] as? String { onBrowserCommand?(command) }
        case Int32(NEUTRINO_CEF_DOWNLOAD_BEGIN):
            guard let id = value["id"] as? Int else { return }
            guard !disposing else {
                command(Int(NEUTRINO_CEF_DOWNLOAD_CANCEL), value: Double(id))
                command(Int(NEUTRINO_CEF_DOWNLOAD_PATH), value: Double(id))
                return
            }
            let key = downloadPrefix + ":" + String(id)
            downloadIDs.insert(key)
            let source = (value["url"] as? String).flatMap(URL.init(string:))
            downloads.beginChromium(id: key, profileID: profileID, suggestedName: value["name"] as? String ?? "Download", sourceURL: source, cancel: { [weak self] in
                self?.command(Int(NEUTRINO_CEF_DOWNLOAD_CANCEL), value: Double(id))
            }, pause: { [weak self] pause in
                self?.command(Int(NEUTRINO_CEF_DOWNLOAD_PAUSE), text: pause ? "1" : "0", value: Double(id))
            }, completion: { [weak self] destination in
                self?.command(Int(NEUTRINO_CEF_DOWNLOAD_PATH), text: destination?.path ?? "", value: Double(id))
            })
        case Int32(NEUTRINO_CEF_DOWNLOAD_UPDATE):
            guard let id = value["id"] as? Int else { return }
            let key = downloadPrefix + ":" + String(id)
            if value["ownerClosed"] as? Bool == true {
                downloads.chromiumOwnerClosed(ids: [key])
                downloadIDs.remove(key)
                return
            }
            let complete = value["complete"] as? Bool == true
            let cancelled = value["cancelled"] as? Bool == true
            let interrupted = value["interrupted"] as? Bool == true
            downloads.updateChromium(id: key, fraction: value["fraction"] as? Double ?? 0,
                                     complete: complete, cancelled: cancelled, interrupted: interrupted)
            if complete || cancelled || interrupted {
                downloadIDs.remove(key)
                if disposing && downloadIDs.isEmpty && closeTask == nil { closePage() }
            }
        case Int32(NEUTRINO_CEF_CREDENTIAL):
            guard let payload = value["payload"] as? String, payload.utf8.count <= 4096,
                  let body = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let origin = body["origin"] as? String, let username = body["username"] as? String, let password = body["password"] as? String,
                  !password.isEmpty, let url = pageURL, (try? LocalCredential.origin(for: url)) == origin else { return }
            onCredential?(origin, String(username.prefix(500)), String(password.prefix(8192)))
        case Int32(NEUTRINO_CEF_READER_CONTEXT):
            if value["clear"] as? Bool == true { readerContexts.removeAll() }
            else if value["destroyed"] as? Bool == true {
                if let uniqueID = value["uniqueID"] as? String, !uniqueID.isEmpty {
                    readerContexts = readerContexts.filter { $0.value != uniqueID }
                } else if let id = value["id"] as? Int { readerContexts.removeValue(forKey: id) }
            } else if let id = value["id"] as? Int, id > 0,
                      let uniqueID = value["uniqueID"] as? String, !uniqueID.isEmpty, uniqueID.utf8.count <= 256 {
                if readerContexts.count >= 16 { readerContexts.remove(at: readerContexts.startIndex) }
                readerContexts[id] = uniqueID
            }
        case Int32(NEUTRINO_CEF_RESULT):
            guard let id = value["id"] as? Int else { return }
            if value["success"] as? Bool == true, let result = value["result"], let data = try? JSONSerialization.data(withJSONObject: result) {
                completeRequest(id, result: .success(data))
            } else { completeRequest(id, result: .failure(ValidationError("The Chromium page operation failed."))) }
        default: break
        }
    }
    private func cancelRequests() {
        readerContexts.removeAll()
        let requests = pending.values; pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: ValidationError("The Chromium page was closed."))
        }
    }
    override var hasActiveDownloads: Bool { !downloadIDs.isEmpty }
    override func requestClose() {
        guard page != nil, !disposing else { onClose?(); return }
        command(Int(NEUTRINO_CEF_REQUEST_CLOSE))
    }
    override func dispose() {
        guard page != nil, closeTask == nil else { return }
        let notice = onNotice
        if !disposing {
            disposing = true
            command(Int(NEUTRINO_CEF_STOP_ADMISSION))
            removeFocusObserver()
            cancelRequests(); super.dispose()
        }
        // A previous cancellation attempt can time out while Chromium still
        // owns a file. Subsequent quit/close attempts must send cancellation
        // again, even after the outer tab and its model have disappeared.
        // CEF must retain the browser and callback receiver until cancellation
        // closes each download writer. Removing the native tab can happen now.
        if downloadIDs.isEmpty { closePage() }
        else {
            runtime.retainWhileClosing(self)
            closeTask = Task { [self] in
                defer { closeTask = nil }
                do {
                    try await downloads.cancelChromiumAndWait(ids: downloadIDs)
                    closePage()
                } catch {
                    // Keep the callback target alive. A late terminal update
                    // releases this page safely; quit remains available to retry.
                    runtime.reportCloseFailure(error.localizedDescription)
                    notice?(error.localizedDescription)
                }
            }
        }
    }
    private func removeFocusObserver() {
        for observer in chromeFocusObservers { NotificationCenter.default.removeObserver(observer) }
        chromeFocusObservers.removeAll()
        if let chromeKeyMonitor { NSEvent.removeMonitor(chromeKeyMonitor) }
        chromeKeyMonitor = nil
    }
    private func closePage() {
        if let page { runtime.api?.close_page(page); self.page = nil }
        runtime.finishedClosing(self)
    }
}
