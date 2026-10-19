// SPDX-License-Identifier: MPL-2.0
import AppKit
import CryptoKit
import SwiftUI
@preconcurrency import WebKit
import NeutrinoCore

/// Engine objects stay inside this adapter. The native shell and recovery do not require a web view.
@MainActor
final class WebTab: BrowserEngineTab, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    override var nativeView: NSView { webView }
    override var isShowingStartPage: Bool { failedNavigationURL == nil && pendingLoadURL == nil && (showingStartPage || webView.url == startPageURL) }
    override var url: URL? { failedNavigationURL ?? pendingLoadURL ?? (isShowingStartPage ? nil : webView.url) }
    override var title: String? { isShowingStartPage || failedNavigationURL != nil ? nil : webView.title }
    override var engineID: BrowserEngineID { .webkit }
    private let downloads: DownloadCenter
    private let profileID: UUID
    private var observations: [NSKeyValueObservation] = []
    private var imageSnapshots: [UUID: WebImageSnapshotRequest] = [:]
    private var pageSnapshots: [UUID: WebPageSnapshotRequest] = [:]
    private var showingStartPage = false
    private var blockingRevision = UUID()
    private var blockingReady = false
    private var compilingRules = false
    private var pendingLoadURL: URL?
    private var blockingRuleList: WKContentRuleList?
    private var disposed = false
    private var failedNavigationURL: URL?
    /// An http address this tab tried as https first; it falls back if https fails.
    private var pendingUpgrade: (secure: URL, original: URL)?
    private var insecureHosts = Set<String>()
    private let startPageURL = URL(string: "about:blank#neutrino-start-" + UUID().uuidString)!
    init(dataStore: WKWebsiteDataStore, downloads: DownloadCenter, profileID: UUID, configuration: WKWebViewConfiguration? = nil) {
        let config = configuration ?? WKWebViewConfiguration()
        if configuration == nil { config.websiteDataStore = dataStore }
        webView = WKWebView(frame: .zero, configuration: config)
        self.downloads = downloads
        self.profileID = profileID
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? 0
                Task { @MainActor [weak self] in self?.progress = value }
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor [weak self] in self?.refresh(false) } },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor [weak self] in self?.refresh(false) } }
        ]
    }
    override func load(_ url: URL) {
        guard !disposed, AddressResolver.isWebURL(url) else { errorMessage = "This address is not supported."; return }
        showingStartPage = false; failedNavigationURL = nil
        if blockingEnabled && !blockingReady {
            pendingLoadURL = url; loading = true; errorMessage = nil
            if !compilingRules { updateBlockingPolicy() }
            return
        }
        pendingLoadURL = nil
        errorMessage = nil; updatePopupPolicy(); webView.load(URLRequest(url: url))
    }
    override func showStartPage() {
        pendingLoadURL = nil
        showingStartPage = true; failedNavigationURL = nil; errorMessage = nil; didStartNavigation()
        imageSnapshots.values.forEach { $0.cancel() }; imageSnapshots.removeAll()
        pageSnapshots.values.forEach { $0.cancel() }; pageSnapshots.removeAll()
        // This trusted local transition stops the old document without closing
        // the adapter, its back history, website store, or active downloads.
        webView.load(URLRequest(url: startPageURL))
    }
    override func updatePopupPolicy() { webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = allowPopups?() == true }
    override func updateBlockingPolicy() {
        blockingRevision = UUID(); let revision = blockingRevision
        let controller = webView.configuration.userContentController
        guard !disposed else { return }
        if !blockingEnabled {
            if let blockingRuleList { controller.remove(blockingRuleList) }
            blockingRuleList = nil; blockingReady = true; compilingRules = false
            if let pendingLoadURL { load(pendingLoadURL) }
            return
        }
        guard let (identifier, rules) = RuleListCache.source(ads: blockAds, exceptions: blockingExceptions, custom: blockingCustom, subscribed: blockingSubscribed) else { return }
        if let compiled = RuleListCache.compiled[identifier] {
            if let previous = blockingRuleList, previous !== compiled { controller.remove(previous) }
            if blockingRuleList !== compiled { controller.add(compiled) }
            blockingRuleList = compiled; blockingReady = true; compilingRules = false
            if let pendingLoadURL { load(pendingLoadURL) }
            return
        }
        blockingReady = blockingRuleList != nil; compilingRules = true
        let finish: @MainActor (WKContentRuleList?, (any Error)?) -> Void = { [weak self] list, error in
            guard let self, !self.disposed, self.blockingEnabled, self.blockingRevision == revision else { return }
            self.compilingRules = false
            if let list {
                RuleListCache.compiled = [identifier: list]
                let controller = self.webView.configuration.userContentController
                if let previous = self.blockingRuleList { controller.remove(previous) }
                controller.add(list); self.blockingRuleList = list; self.blockingReady = true
                if let url = self.pendingLoadURL { self.load(url) }
            } else {
                self.onNotice?(error?.localizedDescription ?? "Content blocking could not load.")
                if let url = self.pendingLoadURL {
                    self.failedNavigationURL = url; self.pendingLoadURL = nil; self.loading = false
                    self.errorMessage = "Blocking rules could not load. Retry or change blocking in Settings."; self.onChange?(false)
                }
            }
        }
        // A list compiled earlier for the same rules is reused, even after relaunch.
        WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            Task { @MainActor in
                if let list { finish(list, nil); return }
                WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { list, error in
                    Task { @MainActor in finish(list, error); RuleListCache.removeStale(keeping: identifier) }
                }
            }
        }
    }
    private func extractText(_ expression: String, timeout: Duration = .seconds(8)) async throws -> String {
        let id=UUID(), request=WebPageSnapshotRequest(timeout: timeout)
        pageSnapshots[id]=request
        defer {pageSnapshots.removeValue(forKey:id)}
        return try await request.capture { [weak self] completion in
            guard let self, !self.disposed else {completion(.failure(CancellationError()));return}
            self.webView.callAsyncJavaScript("return " + expression + ";", arguments: [:], in:nil,in:.defaultClient,completionHandler:completion)
        }
    }
    override func pageText() async throws -> String {try await extractText("(document.body?.innerText ?? '').slice(0, 40000)")}
    // WebKit runs evaluated scripts as a user action, which picture in picture needs.
    override func runPageScript(_ source: String, userGesture: Bool = false, wait: Duration? = nil) async throws -> String { try await extractText(source, timeout: wait ?? .seconds(8)) }
    override func printPage() {
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        if let window = webView.window { operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) }
        else { operation.run() }
    }
    override func pagePDF() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in continuation.resume(with: result) }
        }
    }
    override func pageArchive() async throws -> (data: Data, type: String) {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            webView.createWebArchiveData { result in continuation.resume(with: result) }
        }
        return (data, "webarchive")
    }
    override func fullPageCapture() async throws -> (data: Data, type: String) { (try await pagePDF(), "pdf") }
    override func showDeveloperTools() {
        webView.isInspectable = true
        let preferences = webView.configuration.preferences
        if preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) { preferences.setValue(true, forKey: "developerExtrasEnabled") }
        if webView.responds(to: NSSelectorFromString("_inspector")), let inspector = webView.value(forKey: "_inspector") as? NSObject,
           inspector.responds(to: NSSelectorFromString("show")) {
            inspector.perform(NSSelectorFromString("show"))
        } else { onNotice?("Right-click the page and choose Inspect Element.") }
    }
    override func navigationEntries(back: Bool) async -> [[String: Any]] {
        let list = back ? Array(webView.backForwardList.backList.reversed()) : webView.backForwardList.forwardList
        return list.prefix(15).enumerated().map { index, item in
            ["offset": back ? -(index + 1) : index + 1, "title": item.title ?? "", "url": item.url.absoluteString]
        }
    }
    override func goToHistory(offset: Int) {
        guard let item = webView.backForwardList.item(at: offset) else { return }
        showingStartPage = false; failedNavigationURL = nil; webView.go(to: item)
    }
    override func resourceUsage() async -> (memoryMB: Double, cpuSeconds: Double)? {
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return ProcessUsage.sample(pid)
    }
    override func selectedText() async throws -> String {try await extractText("(window.getSelection()?.toString() ?? '').slice(0, 8000)")}
    override func fillCredential(_ credential: LocalCredential) async throws {
        _ = try await webView.callAsyncJavaScript(credential.autofillScript, arguments: [:], in: nil, contentWorld: .defaultClient)
    }
    override func reload() {
        if let failedNavigationURL { load(failedNavigationURL) }
        else { errorMessage = nil; webView.reload() }
    }
    override func stop() { pendingLoadURL = nil; loading = false; webView.stopLoading() }
    override func goBack() { showingStartPage = false; failedNavigationURL = nil; webView.goBack() }
    override func goForward() { showingStartPage = false; failedNavigationURL = nil; webView.goForward() }
    override func setZoom(_ value: Double) { super.setZoom(value); webView.pageZoom = zoom }
    override func dispose() {
        disposed = true; blockingRevision = UUID()
        imageSnapshots.values.forEach { $0.cancel() }; imageSnapshots.removeAll()
        pageSnapshots.values.forEach { $0.cancel() }; pageSnapshots.removeAll()
        webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
        observations.removeAll(); super.dispose()
    }
    private func refresh(_ finished: Bool) {
        loading = webView.isLoading; canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
        onChange?(finished)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failedNavigationURL = nil; estimatedBlocked = nil
        didStartNavigation()
        imageSnapshots.values.forEach { $0.cancel() }; imageSnapshots.removeAll()
        pageSnapshots.values.forEach { $0.cancel() }; pageSnapshots.removeAll()
        errorMessage = nil; loading = true; refresh(false)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        failedNavigationURL = nil; pendingUpgrade = nil
        // Native history gestures also leave Home without using our commands.
        if webView.url != startPageURL { showingStartPage = false }
        refresh(false)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; refresh(true); onPageLoaded?(); estimateBlocked() }
    /// Resources from blocked domains still named on the finished page: WebKit's rule lists don't report what they block.
    private var estimatedBlocked: Int?
    private var estimatedBlockedTotal = 0
    override var blockedOnPage: Int? { estimatedBlocked }
    override var blockedTotal: Int? { blockingEnabled ? estimatedBlockedTotal : nil }
    private func estimateBlocked() {
        estimatedBlocked = nil
        guard blockingEnabled, !ContentBlocking.isException(url?.host, in: blockingExceptions),
              let script = PageScript.source("blockedCount", ["domains": ContentBlocking.domains(ads: blockAds, custom: blockingCustom)]) else { return }
        let page = url
        Task { @MainActor [weak self] in
            guard let value = try? await self?.runPageScript(script), let count = Int(value), let self, self.url == page else { return }
            self.estimatedBlocked = count; self.estimatedBlockedTotal += count; self.onChange?(false)
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let failure = error as NSError
        // The secure version of an http site failed: load the site as it was asked for.
        if let upgrade = pendingUpgrade, failure.code != NSURLErrorCancelled,
           (failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host == upgrade.secure.host {
            pendingUpgrade = nil
            if let host = upgrade.original.host { insecureHosts.insert(host) }
            webView.load(URLRequest(url: upgrade.original)); return
        }
        // WebKit restores the previous committed URL after a provisional error.
        // Retain the attempted website so the address and Reload still target it.
        if failure.code != NSURLErrorCancelled, !showingStartPage,
           let target = (failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ??
               (failure.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:)),
           AddressResolver.isWebURL(target) { failedNavigationURL = target }
        failed(error)
    }
    private func failed(_ error: Error) {
        loading = false
        if (error as NSError).code != NSURLErrorCancelled { errorMessage = error.localizedDescription }
        refresh(false)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        imageSnapshots.values.forEach { $0.cancel() }; imageSnapshots.removeAll()
        pageSnapshots.values.forEach { $0.cancel() }; pageSnapshots.removeAll()
        loading = false; errorMessage = "The website's process stopped. Reload the page to continue."; refresh(false)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel, preferences); return }
        if url == startPageURL || url.absoluteString == "about:blank" { decisionHandler(.allow, preferences); return }
        // Websites can generate embedded documents without changing the browser's
        // top-level address or gaining access to local files.
        if navigationAction.targetFrame?.isMainFrame == false,
           url.scheme?.lowercased() == "data" || url.absoluteString.components(separatedBy: "#").first == "about:srcdoc" {
            decisionHandler(.allow, preferences); return
        }
        if url.scheme?.lowercased() == "blob" {
            decisionHandler(navigationAction.shouldPerformDownload ? (downloads.acceptsDownloads(for: profileID) ? .download : .cancel) : .allow, preferences); return
        }
        guard AddressResolver.isWebURL(url) else {
            // Only a deliberate click may hand off common non-web protocols.
            if navigationAction.navigationType == .linkActivated, ["mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
                let alert = NSAlert(); alert.messageText = "Open an external app?"
                alert.informativeText = "This website wants to open \(url.scheme ?? "another app")."
                alert.addButton(withTitle: "Open app"); alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            }
            decisionHandler(.cancel, preferences); return
        }
        if navigationAction.shouldPerformDownload { decisionHandler(downloads.acceptsDownloads(for: profileID) ? .download : .cancel, preferences); return }
        if navigationAction.targetFrame?.isMainFrame == true {
            if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.shift), onPeek?(url) == true {
                decisionHandler(.cancel, preferences); return
            }
            if let replacement = rewrittenAddress(url) {
                decisionHandler(.cancel, preferences)
                webView.load(URLRequest(url: replacement)); return
            }
            if let site = ContentBlocking.site(url) { preferences.allowsContentJavaScript = scriptsBlocked?(site) != true }
        }
        decisionHandler(.allow, preferences)
    }
    /// The address to load instead: without tracking parameters, and https for http sites.
    private func rewrittenAddress(_ url: URL) -> URL? {
        var next = url
        if stripsTracking, let stripped = ContentBlocking.strippingTracking(next) { next = stripped }
        // A site that redirects its https address back to http only works over http.
        if next.scheme == "http", let host = next.host, let pending = pendingUpgrade, pending.secure.host == host {
            insecureHosts.insert(host); pendingUpgrade = nil
        }
        if upgradesToHTTPS, next.scheme == "http", let host = next.host, !insecureHosts.contains(host),
           host.contains("."), !host.hasSuffix(".local"), host.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789.:").inverted) != nil,
           var components = URLComponents(url: next, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            if components.port == 80 { components.port = nil }
            if let secure = components.url { pendingUpgrade = (secure, next); next = secure }
        }
        return next == url ? nil : next
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : (downloads.acceptsDownloads(for: profileID) ? .download : .cancel))
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { downloads.track(download, profileID: profileID) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { downloads.track(download, profileID: profileID) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        guard url == nil || url?.absoluteString == "about:blank" || url?.scheme == "blob" || url.map(AddressResolver.isWebURL) == true else { return nil }
        // WebKit's javaScriptCanOpenWindowsAutomatically setting blocks unsolicited popups.
        // Return a view using the supplied configuration; WebKit preserves the request and opener.
        let child = WebTab(dataStore: configuration.websiteDataStore, downloads: downloads, profileID: profileID, configuration: configuration)
        guard onCreateWindow?(child, url) == true else { child.dispose(); return nil }
        return child.webView
    }
    func webViewDidClose(_ webView: WKWebView) { onClose?() }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.message = "Choose files to share with \(frame.securityOrigin.host)."
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories; panel.canChooseFiles = true
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = siteAlert(frame, message); alert.addButton(withTitle: "OK"); alert.runModal()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = siteAlert(frame, message); alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let alert = siteAlert(frame, prompt); let input = NSTextField(string: defaultText ?? "")
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24); alert.accessoryView = input
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? input.stringValue : nil)
    }
    private func siteAlert(_ frame: WKFrameInfo, _ message: String) -> NSAlert {
        let alert = NSAlert(); alert.messageText = "\(frame.securityOrigin.host) says"
        alert.informativeText = String(message.prefix(4000)); return alert
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        guard origin.protocol == "https" else { decisionHandler(.deny); return }
        let site = origin.host.hasPrefix("www.") ? String(origin.host.dropFirst(4)) : origin.host
        let kinds = type == .camera ? ["camera"] : type == .microphone ? ["microphone"] : ["camera", "microphone"]
        let saved = kinds.map { sitePermission?(site, $0) }
        if saved.allSatisfy({ $0 == "allow" }) { decisionHandler(.grant); return }
        if saved.contains(where: { $0 == "block" }) { decisionHandler(.deny); return }
        let alert = NSAlert(); alert.messageText = "Allow \(origin.host) to use your \(kinds.count == 2 ? "camera and microphone" : kinds[0])?"
        alert.informativeText = "This permission applies to this website. macOS may also ask for permission."
        alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Remember for this site"
        alert.addButton(withTitle: "Don't allow"); alert.addButton(withTitle: "Allow")
        let allowed = alert.runModal() == .alertSecondButtonReturn
        if alert.suppressionButton?.state == .on { for kind in kinds { onSitePermission?(site, kind, allowed ? "allow" : "block") } }
        decisionHandler(allowed ? .grant : .deny)
    }
    override func capturePNG() async throws -> Data {
        let id = UUID(), request = WebImageSnapshotRequest()
        imageSnapshots[id] = request
        defer { imageSnapshots.removeValue(forKey: id) }
        return try await request.capture(webView)
    }
    override func pageHTML() async throws -> String {
        let script = "(() => { const html = document.documentElement ? new XMLSerializer().serializeToString(document.documentElement) : ''; if (html.length > 1048576) throw new Error('Page snapshot exceeds 1 MB.'); return html; })()"
        let id = UUID(), request = WebPageSnapshotRequest()
        pageSnapshots[id] = request
        defer { pageSnapshots.removeValue(forKey: id) }
        return try await request.capture { completion in
            // The isolated client world uses native DOM primitives even if a page
            // replaces XMLSerializer in its own JavaScript world.
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient, completionHandler: completion)
        }
    }
    override func find(_ text: String, backwards: Bool = false) {
        guard !text.isEmpty else { return }
        let config = WKFindConfiguration(); config.backwards = backwards; config.wraps = true
        webView.find(text, configuration: config) { _ in }
    }
}

/// WebKit cannot cancel an individual JavaScript evaluation. Release the host's
/// wait on cancellation/deadline, and let late callbacks address only this request.
@MainActor
final class WebPageSnapshotRequest {
    private let timeout: Duration
    private var continuation: CheckedContinuation<String, any Error>?
    private var watchdog: Task<Void, Never>?
    private var hasStarted = false
    private var cancelled = false
    init(timeout: Duration = .seconds(8)) { self.timeout = timeout }

    func capture(using evaluate: (@escaping @MainActor @Sendable (Result<Any, any Error>) -> Void) -> Void) async throws -> String {
        guard !hasStarted else { throw ValidationError("A page snapshot request can only be used once.") }
        hasStarted = true
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                watchdog = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(.failure(ValidationError("The page did not respond to Reader in time. Try reloading it.")))
                }
                evaluate { [weak self] result in self?.finish(result) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func cancel() { cancelled = true; finish(.failure(CancellationError())) }
    private func finish(_ result: Result<Any, any Error>) {
        guard let continuation else { return }
        self.continuation = nil; watchdog?.cancel(); watchdog = nil
        switch result {
        case .failure(let error): continuation.resume(throwing: error)
        case .success(let value):
            guard let html = value as? String, html.utf8.count <= ReaderRequest.maximumHTMLBytes else {
                continuation.resume(throwing: ValidationError("The page snapshot exceeds 1 MB.")); return
            }
            continuation.resume(returning: html)
        }
    }
}
struct WebViewHost: NSViewRepresentable {
    let tab: BrowserEngineTab
    func makeNSView(context: Context) -> EngineViewContainer { EngineViewContainer(page: tab.nativeView) }
    func updateNSView(_ nsView: EngineViewContainer, context: Context) { nsView.mount(tab.nativeView) }
    static func dismantleNSView(_ nsView: EngineViewContainer, coordinator: ()) { nsView.unmount() }
}

/// SwiftUI owns each container; the adapter retains its page across layouts.
/// An outgoing representable must never detach a page already mounted elsewhere.
@MainActor
final class EngineViewContainer: NSView {
    private var page: NSView?
    var isPreviewing = false {
        didSet { setAccessibilityHidden(isPreviewing) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return isPreviewing && hit != nil ? self : hit
    }
    init(page: NSView) { super.init(frame: .zero); mount(page) }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func mount(_ page: NSView) {
        guard self.page !== page || page.superview !== self else { return }
        unmount()
        self.page = page
        if page.superview !== self {
            page.removeFromSuperview()
            page.translatesAutoresizingMaskIntoConstraints = true
            page.autoresizingMask = [.width, .height]
            addSubview(page)
        }
        page.frame = bounds
    }
    override func layout() {
        super.layout()
        if let page, page.superview === self { page.frame = bounds }
    }
    func unmount() {
        if let page, page.superview === self { page.removeFromSuperview() }
        page = nil
    }
}

@MainActor
private final class WebImageSnapshotRequest {
    private var continuation: CheckedContinuation<Data, any Error>?
    private var watchdog: Task<Void, Never>?
    private var cancelled = false
    func capture(_ view: WKWebView) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                watchdog = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    self?.finish(nil, ValidationError("The page could not be captured in time."))
                }
                view.takeSnapshot(with: nil) { [weak self] image, error in
                    Task { @MainActor in self?.finish(image, error) }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func cancel() { cancelled = true; finish(nil, CancellationError()) }
    private func finish(_ image: NSImage?, _ error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil; watchdog?.cancel(); watchdog = nil
        if let error { continuation.resume(throwing: error); return }
        guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]), png.count <= 32 * 1024 * 1024 else {
            continuation.resume(throwing: ValidationError("The page could not be captured within the 32 MB limit.")); return
        }
        continuation.resume(returning: png)
    }
}

/// Compiled WebKit rule lists, shared by every tab. The store keeps them across
/// launches under an identifier derived from their content.
@MainActor
enum RuleListCache {
    private static var lastKey: [String]?
    private static var last: (identifier: String, source: String)?
    static var compiled: [String: WKContentRuleList] = [:]
    static func source(ads: Bool, exceptions: [String], custom: [String], subscribed: [String]) -> (String, String)? {
        let key = [ads ? "ads" : "trackers", exceptions.joined(separator: ","), custom.joined(separator: ","), String(subscribed.count), String(subscribed.hashValue)]
        if key == lastKey, let last { return (last.identifier, last.source) }
        guard let rules = try? ContentBlocking.webKitRules(ads: ads, exceptions: exceptions, custom: custom, subscribed: Array(subscribed.prefix(110_000))) else { return nil }
        let digest = SHA256.hash(data: Data(rules.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let identifier = "org.neutrino.blocking." + digest
        lastKey = key; last = (identifier, rules)
        return (identifier, rules)
    }
    /// Removes lists compiled for rules no longer in use.
    static func removeStale(keeping identifier: String) {
        WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { ids in
            let stale = (ids ?? []).filter { $0.hasPrefix("org.neutrino.blocking.") && $0 != identifier } + ["org.neutrino.blocking.v1"]
            Task { @MainActor in
                for id in stale { WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in } }
            }
        }
    }
}
