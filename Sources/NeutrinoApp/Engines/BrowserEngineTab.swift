// SPDX-License-Identifier: MPL-2.0
import AppKit
import Darwin
import SwiftUI
import NeutrinoCore

enum NativeTabCommand { case new, close, reopen, previous, next }

/// Native browser controls observe this state; engines own their website context.
@MainActor
class BrowserEngineTab: NSObject, ObservableObject {
    @Published var faviconDataURL: String?
    private var faviconOrigin: String?
    private var faviconTask: Task<Void, Never>?
    func updateSiteIcon(for url: URL) {
        let origin = url.scheme.map { $0 + "://" + (url.host ?? "") + ":" + String(url.port ?? 0) }
        guard origin != faviconOrigin else { return }
        faviconOrigin = origin; faviconDataURL = nil; faviconTask?.cancel()
        faviconTask = Task { @MainActor [weak self] in
            let icon = await SiteIcon.load(for: url)
            guard !Task.isCancelled, let self, self.faviconOrigin == origin else { return }
            self.faviconDataURL = icon; self.onChange?(false)
        }
    }
    @Published var loading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var errorMessage: String?
    @Published var zoom = 1.0
    @Published private(set) var navigationRevision = UUID()
    var onChange: ((Bool) -> Void)?
    var onCreateWindow: ((BrowserEngineTab, URL?) -> Bool)?
    var onClose: (() -> Void)?
    var onNotice: ((String) -> Void)?
    var onActivate: (() -> Void)?
    var onBrowserCommand: ((String) -> Void)?
    var allowPopups: (() -> Bool)? { didSet { updatePopupPolicy() } }
    /// Set before `blockingEnabled`, whose assignment applies the whole policy.
    var blockAds = true
    var blockingExceptions: [String] = []
    var blockingCustom: [String] = []
    /// A sign-in submitted on the page's own origin: origin, username, password.
    var onCredential: ((String, String, String) -> Void)? { didSet { if onCredential != nil { installCredentialCapture() } } }
    func installCredentialCapture() {}
    /// Domains from subscribed filter lists.
    var blockingSubscribed: [String] = []
    /// Called after each page finishes loading, so per-site tools can be reapplied.
    var onPageLoaded: (() -> Void)?
    /// Shift-clicked links open in a floating preview when this returns true.
    var onPeek: ((URL) -> Bool)?
    /// Remembers a camera or microphone answer: site, "camera"/"microphone", "allow"/"block".
    var onSitePermission: ((String, String, String) -> Void)?
    /// The saved answer for a site and permission, if any.
    var sitePermission: ((String, String) -> String?)?
    /// Whether scripts are turned off for a site.
    var scriptsBlocked: ((String) -> Bool)?
    var upgradesToHTTPS = true
    var stripsTracking = true
    var blockingEnabled = true { didSet { updateBlockingPolicy() } }
    var hasNativeNavigationChrome: Bool { false }
    func focusAddressBar() -> Bool { false }
    var nativeView: NSView { preconditionFailure("An engine must provide its native view") }
    var isShowingStartPage: Bool { false }
    var url: URL? { nil }
    var title: String? { nil }
    var engineID: BrowserEngineID { preconditionFailure("An engine must identify itself") }
    func refreshActiveContent() {}
    private var interfaceEditors = Set<UUID>()
    var interfaceEditing: Bool { !interfaceEditors.isEmpty }
    func setInterfaceEditing(_ value: Bool, owner: UUID) {
        if value { interfaceEditors.insert(owner) } else { interfaceEditors.remove(owner) }
    }
    func performNativeTabCommand(_ command: NativeTabCommand) -> Bool { false }
    var chromiumSessionPages: [ChromiumSessionPage]? { nil }
    func restoreChromiumSessionPages(_ pages: [ChromiumSessionPage]) {}
    func load(_ url: URL) { preconditionFailure("An engine must implement navigation") }
    func showStartPage() { preconditionFailure("An engine must implement its native start page transition") }
    func reload() { preconditionFailure("An engine must implement reload") }
    func stop() { preconditionFailure("An engine must implement stop") }
    func goBack() { preconditionFailure("An engine must implement back navigation") }
    func goForward() { preconditionFailure("An engine must implement forward navigation") }
    func didStartNavigation() { navigationRevision = UUID() }
    func setZoom(_ value: Double) { zoom = min(3, max(0.5, value)) }
    func updatePopupPolicy() {}
    func updateBlockingPolicy() {}
    func pageText() async throws -> String { throw ValidationError("This engine cannot read page text.") }
    func selectedText() async throws -> String { throw ValidationError("This engine cannot read selected text.") }
    func fillCredential(_ credential: LocalCredential) async throws { throw ValidationError("Autofill is unavailable in this engine.") }
    /// Runs Brave-style fingerprinting protection in the page's own world before each document's scripts.
    func installFingerprintProtection(_ source: String) {}
    /// Fills the login once the person uses the form, rather than as the page loads.
    func fillCredentialOnUse(_ credential: LocalCredential) async throws { throw ValidationError("Autofill is unavailable in this engine.") }
    func focus() { if !interfaceEditing { nativeView.window?.makeFirstResponder(nativeView) } }
    func find(_ text: String, backwards: Bool = false) { preconditionFailure("An engine must implement find") }
    func pageHTML() async throws -> String { throw ValidationError("This engine cannot capture page HTML.") }
    func capturePNG() async throws -> Data { throw ValidationError("This engine cannot capture the page.") }
    /// Runs one of the shared page scripts in an isolated world. Scripts return strings.
    /// Runs a generated page script; `wait` allows a script that returns a promise to settle later.
    func runPageScript(_ source: String, userGesture: Bool = false, wait: Duration? = nil) async throws -> String { throw ValidationError("This engine cannot run page tools.") }
    func setMuted(_ value: Bool) {
        guard let script = PageScript.source("mute", ["value": value]) else { return }
        Task { _ = try? await runPageScript(script) }
    }
    func printPage() { onNotice?("Printing is unavailable for this page.") }
    func pagePDF() async throws -> Data { throw ValidationError("This engine cannot save a PDF.") }
    func pageArchive() async throws -> (data: Data, type: String) { (Data(try await pageHTML().utf8), "html") }
    func fullPageCapture() async throws -> (data: Data, type: String) { (try await capturePNG(), "png") }
    func showDeveloperTools() { onNotice?("Developer tools are unavailable for this page.") }
    func navigationEntries(back: Bool) async -> [[String: Any]] { [] }
    func goToHistory(offset: Int) {}
    func applyScriptPolicy() {}
    func setNetworkLimit(bytesPerSecond: Int) {}
    /// WebKit already hides local addresses from WebRTC with mDNS candidates.
    func setPrivacyPreferences(httpsOnly: Bool, blockThirdPartyCookies: Bool, hideLocalIP: Bool) {}
    /// Clears cookies and cache; with cookies, also the storage of `hosts` and of every site with cookies.
    /// `since` limits cookies to those set after it; `.distantPast` clears them all.
    func clearWebsiteData(cookies: Bool, cache: Bool, hosts: [String] = [], since: Date = .distantPast) async {}
    func clearSiteData(host: String) async {}
    func cookieDomains() async -> [String] { [] }
    /// Requests blocked on the current page, when the engine counts them.
    var blockedOnPage: Int? { nil }
    /// Requests blocked since the tab opened, when the engine counts them.
    var blockedTotal: Int? { nil }
    /// Memory in megabytes and processor time in seconds, when the engine reports them.
    func resourceUsage() async -> (memoryMB: Double, cpuSeconds: Double)? { nil }
    /// Runs the page's work `rate` times slower (1 is full speed), when the engine can.
    func setProcessorThrottle(_ rate: Double) {}
    var hasActiveDownloads: Bool { false }
    func requestClose() { onClose?() }
    func dispose() { faviconTask?.cancel(); faviconTask = nil; onChange = nil; onCreateWindow = nil; onClose = nil; onNotice = nil; onActivate = nil; onBrowserCommand = nil; allowPopups = nil; onPageLoaded = nil; onPeek = nil; onSitePermission = nil; sitePermission = nil; scriptsBlocked = nil }
}

/// Page scripts are generated in Rust so both engines run the same code.
enum PageScript {
    static func source(_ kind: String, _ values: [String: Any] = [:]) -> String? {
        var request = values; request["op"] = "pageScript"; request["kind"] = kind
        return try? RustCore.request(request) as? String
    }
}

/// Memory footprint and processor time of one process, from the kernel.
enum ProcessUsage {
    static func sample(_ pid: Int32) -> (memoryMB: Double, cpuSeconds: Double)? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        let nanoseconds = timebase.denom == 0 ? ticks : ticks * Double(timebase.numer) / Double(timebase.denom)
        return (Double(info.ri_phys_footprint) / 1_048_576, nanoseconds / 1_000_000_000)
    }
}

/// Brave-style fingerprinting protection: one random key per launch, so each site sees
/// stable noise for the session and different sites see different noise.
@MainActor
enum FingerprintProtection {
    static let seed = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    static func script(exceptions: [String]) -> String? {
        PageScript.source("farbling", ["seed": seed, "exceptions": Array(exceptions.prefix(500))])
    }
}
