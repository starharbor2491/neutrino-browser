// SPDX-License-Identifier: MPL-2.0
import AppKit
import CoreFoundation
import Darwin
import SwiftUI
import NeutrinoCore

/// CI-only launch verification using the actual app window and an isolated, disposable data folder.
@MainActor
enum AppSmokeTest {
    static func run() async {
        trace("Starting packaged-app smoke test")
        guard let outputPath = ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_OUTPUT"],
              ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_DATA"] != nil else {
            fail("Smoke test requires isolated data and output directories."); return
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            trace("Waiting for browser window")
            let deadline = Date().addingTimeInterval(20)
            while AppDelegate.state?.ready != true || NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) == nil || AppDelegate.state?.windows.values.compactMap(\.model).isEmpty != false {
                if let error = AppDelegate.state?.startupError { throw ValidationError(error) }
                if Date() > deadline { throw ValidationError("The packaged app did not open a browser window.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let app = AppDelegate.state, let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let browser = app.windows.values.compactMap(\.model).first else { throw ValidationError("Browser state is unavailable.") }
            if ProcessInfo.processInfo.environment["NEUTRINO_CHROMIUM_EXTENSION_RESTART"] == "1" {
                try await ChromiumAcceptance.verifyStoreRestart(app: app)
                guard await app.flush() else { throw ValidationError(app.notice ?? "Could not save restart acceptance data.") }
                trace("Chromium real-process restart acceptance passed")
                requestNormalQuit()
                return
            }
            trace("Browser window opened")
            try await measureIdle("initial-shell-onboarding")
            if let view = window.contentView { try capture(view, to: output.appendingPathComponent("Neutrino-first-launch.png")) }
            try await captureOnboarding(app: app, output: output)
            window.makeKeyAndOrderFront(nil)
            app.library.preferences.completedOnboarding = true
            try await RustShellAcceptance.verify(window: window, app: app, model: browser, output: output)
            if let address = ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_URL"] {
                trace("Navigating to loopback HTTP fixture")
                let navigationStarted = ProcessInfo.processInfo.systemUptime
                browser.navigate(address)
                let pageDeadline = Date().addingTimeInterval(10)
                while browser.activeWebTab.title != "Neutrino HTTP fixture" || browser.activeWebTab.loading {
                    if Date() > pageDeadline { throw ValidationError("The packaged app could not navigate to its HTTP test page.") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard browser.activeWebTab.url?.scheme == "http" else { throw ValidationError("HTTP navigation did not reach the fixture.") }
                if ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_PERFORMANCE"] == "1" {
                    trace("SMOKE_PERFORMANCE_NAVIGATION_SECONDS \(ProcessInfo.processInfo.systemUptime - navigationStarted)")
                }
                try await measureIdle("loaded-webkit-loopback")
                trace("Extracting reader text")
                let text = try await app.readerText(from: browser.activeWebTab)
                guard text.contains("Local browser check") else { throw ValidationError("Reader could not read the HTTP fixture.") }
                try await RustShellAcceptance.verifyPageGeometry(window: window, model: browser)
                trace("Verifying split panes and tree tabs")
                browser.panel = nil
                var config = browser.configuration
                config.layout.tabs = .leading; config.layout.treeTabs = true; config.layout.split = .sideBySide
                app.applyConfiguration(config, to: browser.session.spaceID); browser.synchronizeSplit()
                guard let pair = browser.session.split else { throw ValidationError("Split panes did not open.") }
                browser.selectTab(pair.second); browser.navigate(address)
                let splitDeadline = Date().addingTimeInterval(10)
                while browser.webTab(pair.second).title != "Neutrino HTTP fixture" || browser.webTab(pair.second).loading {
                    if Date() > splitDeadline { throw ValidationError("The second browsing pane could not navigate.") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard browser.webTab(pair.first) !== browser.webTab(pair.second), browser.session.split?.first == pair.first else { throw ValidationError("Browsing panes were not independent.") }
                _ = browser.session.setParent(pair.second, to: pair.first)
                try await Task.sleep(for: .milliseconds(500))
                guard let view = window.contentView else { throw ValidationError("Cannot capture split panes.") }
                try capture(view, to: output.appendingPathComponent("Neutrino-split.png"))
                browser.selectOtherPane()
                guard browser.session.selectedTabID == pair.first else { throw ValidationError("Switching panes did not update the address context.") }
                if ProcessInfo.processInfo.environment["NEUTRINO_CHROMIUM_PACKAGE"] != nil {
                    trace("Verifying bundled optional Chromium runtime")
                    guard ChromiumRuntime.shared.isInstalled(in: app.dataDirectory) else { throw ValidationError("The Chromium development variant has no bundled runtime.") }
                    let id = browser.session.selectedTabID
                    trace("Reopening an embedded tab in Chromium")
                    browser.changeEngine(id, to: .chromium)
                    let chromiumDeadline = Date().addingTimeInterval(30)
                    while browser.webTab(id).title != "Neutrino HTTP fixture" || browser.webTab(id).loading {
                        if let error = browser.webTab(id).errorMessage { throw ValidationError(error) }
                        if Date() > chromiumDeadline { throw ValidationError("Embedded Chromium did not render the HTTP fixture.") }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard let chromium = browser.webTab(id) as? ChromiumTab else { throw ValidationError("Chromium adapter is unavailable.") }
                    let hostDeadline = ContinuousClock.now.advanced(by: .seconds(10))
                    while chromium.nativeView.window !== window || chromium.chromeWindow?.parent !== window || !chromium.chromeStyle {
                        guard ContinuousClock.now < hostDeadline else {
                            throw ValidationError("Chromium was not hosted inside the actual Neutrino window (anchorWindow=\(chromium.nativeView.window?.windowNumber ?? -1), expected=\(window.windowNumber), chromeWindow=\(chromium.chromeWindow?.windowNumber ?? -1), parent=\(chromium.chromeWindow?.parent?.windowNumber ?? -1), visible=\(chromium.chromeWindow?.isVisible == true), bounds=\(chromium.nativeView.bounds)).")
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    await captureWindow(window, to: output.appendingPathComponent("Neutrino-chromium-initial-window.png"))
                    if let chromeWindow = chromium.chromeWindow {
                        await captureWindow(chromeWindow, to: output.appendingPathComponent("Neutrino-chromium-initial-toolbar-window.png"))
                    }
                    var acceptanceFailures: [String] = []
                    do { try await ChromiumAcceptance.verifyChromeGeometry(chromium, ownerWindow: window) }
                    catch {
                        let message = "Initial Chrome hosting: " + error.localizedDescription
                        acceptanceFailures.append(message); trace(message)
                    }
                    do {
                        try await measureIdle("loaded-chromium-with-webkit-pane")
                        trace("Verifying Reader captures in an isolated Chromium world")
                        _ = try await evaluate(chromium, "(() => { window.neutrinoOriginalSerializer = window.XMLSerializer; window.neutrinoSnapshotTouched = false; window.XMLSerializer = class { constructor() { window.neutrinoSnapshotTouched = true; } serializeToString() { return '<html><body>Wrong page-world snapshot</body></html>'; } }; return 'ready'; })()")
                        guard try await app.readerText(from: chromium).contains("Local browser check"),
                              try await evaluate(chromium, "String(window.neutrinoSnapshotTouched)") == "false" else { throw ValidationError("Chromium Reader invoked the page's overridden serializer.") }
                        _ = try await evaluate(chromium, "(() => { window.XMLSerializer = window.neutrinoOriginalSerializer; delete window.neutrinoOriginalSerializer; delete window.neutrinoSnapshotTouched; return 'restored'; })()")
                        trace("Cancelling a Chromium page before its new context is ready")
                        let liveBeforeCancellation = ChromiumRuntime.shared.api?.live_pages()
                        let pendingSession = UUID()
                        ChromiumRuntime.shared.beginPrivateSession(pendingSession)
                        defer { ChromiumRuntime.shared.closePrivateSession(pendingSession) }
                        let pending = try ChromiumRuntime.shared.makeTab(profileID: UUID(), privateSessionID: pendingSession, dataDirectory: app.dataDirectory)
                        pending.dispose()
                        ChromiumRuntime.shared.closePrivateSession(pendingSession)
                        guard ChromiumRuntime.shared.api?.live_pages() == liveBeforeCancellation else { throw ValidationError("An uninitialized Chromium page survived cancellation.") }
                        try await Task.sleep(for: .milliseconds(250))
                        guard ChromiumRuntime.shared.api?.live_pages() == liveBeforeCancellation else { throw ValidationError("A cancelled Chromium page was created later.") }
                        trace("Checking Chromium profile and private-window isolation")
                        let normalToken = "neutrinoNormal" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                        _ = try await evaluate(chromium, "document.cookie = '\(normalToken)=1; path=/; max-age=60'; localStorage.setItem('\(normalToken)', '1'); document.cookie")
                        guard try await evaluate(chromium, "document.cookie").contains(normalToken) else { throw ValidationError("The normal Chromium profile could not set its test cookie.") }
                        var probes: [(BrowserModel, NSWindow)] = []
                        defer { for (model, window) in probes { model.closeWindow(); window.close() } }
                        let privateToken = "neutrinoPrivate" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                        for index in 0..<2 {
                            let probe = try await openProbe(app: app, privateBrowsing: true, profileID: nil, address: address + "?private-probe=\(index)")
                            probes.append(probe)
                            guard let tab = probe.0.activeWebTab as? ChromiumTab else { throw ValidationError("A private probe used the wrong engine.") }
                            let cookies = try await evaluate(tab, "document.cookie")
                            guard !cookies.contains(normalToken), !cookies.contains(privateToken) else { throw ValidationError("Chromium cookies leaked into another private window.") }
                            guard try await evaluate(tab, "String(localStorage.getItem('\(normalToken)'))") == "null",
                                  try await evaluate(tab, "String(localStorage.getItem('\(privateToken)'))") == "null" else { throw ValidationError("Chromium local storage leaked into a private window.") }
                            if index == 0 {
                                _ = try await evaluate(tab, "document.cookie = '\(privateToken)=1; path=/'; localStorage.setItem('\(privateToken)', '1'); document.cookie")
                                trace("Checking private Chromium popup policy and opener")
                                try await verifyPopups(in: probe.0, app: app)
                            }
                        }
                        let separateProfile = Profile(name: "Isolation probe"); app.library.profiles.append(separateProfile)
                        let separate = try await openProbe(app: app, privateBrowsing: false, profileID: separateProfile.id, address: address)
                        probes.append(separate)
                        guard let separateTab = separate.0.activeWebTab as? ChromiumTab else { throw ValidationError("The separate profile used the wrong engine.") }
                        let separateCookies = try await evaluate(separateTab, "document.cookie")
                        guard !separateCookies.contains(normalToken) else { throw ValidationError("Chromium profile cookies were not separated.") }
                        guard try await evaluate(separateTab, "String(localStorage.getItem('\(normalToken)'))") == "null" else { throw ValidationError("Chromium profile local storage was not separated.") }
                        guard !app.library.history.contains(where: { $0.url.query?.contains("private-probe") == true }),
                              !app.library.sessions.flatMap(\.tabs).contains(where: { $0.url?.query?.contains("private-probe") == true }) else { throw ValidationError("Private Chromium browsing entered saved history or sessions.") }
                        for (model, window) in probes { model.closeWindow(); window.close() }; probes.removeAll()
                        trace("Checking normal Chromium popup policy and opener")
                        try await verifyPopups(in: browser, app: app)
                        let captureResponse = try await chromium.request("Page.captureScreenshot", parameters: ["format": "png", "captureBeyondViewport": false])
                        guard let captureObject = try JSONSerialization.jsonObject(with: captureResponse) as? [String: Any],
                              let encoded = captureObject["data"] as? String, let contentPNG = Data(base64Encoded: encoded),
                              contentPNG.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), contentPNG.count > 1000 else {
                            throw ValidationError("Chromium could not capture its rendered page.")
                        }
                        try contentPNG.write(to: output.appendingPathComponent("Neutrino-chromium-content.png"))
                        trace("Checking ordinary HTTPS browsing in Chromium")
                        browser.navigate("https://example.com/")
                        let httpsDeadline = Date().addingTimeInterval(20)
                        while chromium.title != "Example Domain" || chromium.loading {
                            if let error = chromium.errorMessage { throw ValidationError(error) }
                            if Date() > httpsDeadline { throw ValidationError("Chromium did not load its HTTPS check page.") }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        let httpsPage = try await evaluate(chromium, "JSON.stringify({href: location.href, title: document.title, body: document.body ? document.body.innerText.slice(0, 300) : null})")
                        trace("HTTPS probe: reported address \(chromium.url?.absoluteString ?? "nil"); document \(httpsPage)")
                        guard chromium.url?.scheme == "https" else { throw ValidationError("Chromium HTTPS address was not reported: \(chromium.url?.absoluteString ?? "nil").") }
                        let httpsReader = try await app.readerText(from: chromium)
                        guard try await evaluate(chromium, "String(location.protocol)") == "https:", httpsReader.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else {
                            throw ValidationError("Chromium HTTPS reader did not return the loaded page's body (\(httpsReader.count) characters).")
                        }
                        try await Task.sleep(for: .milliseconds(500))
                        guard let view = window.contentView else { throw ValidationError("Cannot capture embedded Chromium.") }
                        try capture(view, to: output.appendingPathComponent("Neutrino-chromium.png"))
                        // WindowServer capture includes GPU-backed layers omitted by Cocoa bitmap caching.
                        await captureWindow(window, to: output.appendingPathComponent("Neutrino-chromium-window.png"))
                        if let chromeWindow = chromium.chromeWindow { await captureWindow(chromeWindow, to: output.appendingPathComponent("Neutrino-chromium-toolbar-window.png")) }
                    } catch {
                        let message = "Chromium browsing/privacy: " + error.localizedDescription
                        acceptanceFailures.append(message); trace(message)
                    }
                    // These checks restore their own windows/session state. Collect
                    // independent failures so a shortcut defect does not conceal
                    // extension incompatibility; every failure still rejects the run.
                    do { try await ChromiumAcceptance.verifyKeyboardRouting(browser: browser, ownerWindow: window) }
                    catch {
                        let message = "Keyboard routing: " + error.localizedDescription
                        acceptanceFailures.append(message); trace(message)
                    }
                    do { try await ChromiumAcceptance.verifyHostAndManagement(chromium, app: app, ownerWindow: window) }
                    catch {
                        let message = "Chrome hosting/extensions: " + error.localizedDescription
                        acceptanceFailures.append(message); trace(message)
                    }
                    do { try await ChromiumAcceptance.verifySessionCookieAfterLastBrowserCloses(app: app) }
                    catch {
                        let message = "Session-cookie continuity: " + error.localizedDescription
                        acceptanceFailures.append(message); trace(message)
                    }
                    if !acceptanceFailures.isEmpty { throw ValidationError(acceptanceFailures.joined(separator: "\n")) }
                    trace("Closing Chromium while WebKit and Neutrino remain open")
                    browser.closeTab(id)
                    let closeDeadline = Date().addingTimeInterval(10)
                    while ChromiumRuntime.shared.api?.live_pages() != 0 {
                        if Date() > closeDeadline { throw ValidationError("The Chromium page did not close.") }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard window.isVisible, browser.activeWebTab.engineID == .webkit else { throw ValidationError("Closing Chromium also closed the native window or WebKit pane.") }
                    trace("Leaving the native extension manager open to verify quit ownership")
                    browser.sheet = .extensions
                    try await ChromiumAcceptance.verifyExtensionSheet(browser: browser, ownerWindow: window)
                    trace("Embedded Chromium runtime check passed")
                }
            }
            trace("Saving browser data")
            guard await app.flush() else { throw ValidationError(app.notice ?? "App data could not be saved.") }
            trace("Neutrino packaged-app smoke test passed.")
            // Return this actor job before AppKit enters its deferred-termination loop.
            // The extension-manager sheet can leave AppKit in modal-panel mode.
            requestNormalQuit()
        } catch { fail(error.localizedDescription) }
    }
    private static func requestNormalQuit() {
        trace("Scheduling normal quit on the main run loop")
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                let mode = CFRunLoopCopyCurrentMode(runLoop).map { String(describing: $0) } ?? "none"
                trace("Requesting normal quit: main=\(Thread.isMainThread), mode=\(mode), delegate=\(String(describing: NSApp.delegate)), modal=\(NSApp.modalWindow != nil), sheet=\(NSApp.windows.contains { $0.attachedSheet != nil })")
                NSApp.terminate(nil)
                trace("Normal quit request returned")
            }
        }
        CFRunLoopWakeUp(runLoop)
    }
    private static func moduleSectionPicker(in root: NSView) -> NSSegmentedControl? {
        if let picker = root as? NSSegmentedControl, !picker.isHidden,
           (0..<picker.segmentCount).contains(where: { picker.label(forSegment: $0) == "Updates" }) { return picker }
        for child in root.subviews { if let picker = moduleSectionPicker(in: child) { return picker } }
        return nil
    }
    private static func layoutRegion(_ identifier: String, in root: NSView) -> NSView? {
        if root.identifier?.rawValue == identifier, !root.isHidden, root.bounds.width > 0, root.bounds.height > 0 { return root }
        for child in root.subviews { if let match = layoutRegion(identifier, in: child) { return match } }
        return nil
    }
    private static func captureOnboarding(app: AppState, output: URL) async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 780), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: OnboardingView(previewStep: 0).environmentObject(app))
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        let web = try await RustShellAcceptance.waitForShell(in:window)
        var previous: Data?
        for step in 0..<7 {
            if step > 0 { try await RustShellAcceptance.action(["op":"setup-next"],web:web) }
            guard (try await web.evaluateJavaScript("!!document.querySelector('.onboarding.step-\(step)')")) as? Bool == true else { throw ValidationError("Setup did not render step \(step+1).") }
            // WebKit renders out of process; NSView.cacheDisplay produces black frames.
            let image = try await web.takeSnapshot(with:nil)
            guard let tiff=image.tiffRepresentation, let bitmap=NSBitmapImageRep(data:tiff), let png=bitmap.representation(using:.png,properties:[:]), png.count>1000, png != previous else { throw ValidationError("Setup capture did not change between steps.") }
            try png.write(to:output.appendingPathComponent("Neutrino-setup-\(step+1).png")); previous=png
        }
        trace("Captured seven distinct native WebKit setup screens")
    }

    private static func capture(_ view: NSView, to url: URL) throws {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ValidationError("Cannot capture \(url.lastPathComponent).") }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let png = image.representation(using: .png, properties: [:]), png.count > 1000 else { throw ValidationError("The \(url.lastPathComponent) screenshot was empty.") }
        try png.write(to: url)
    }
    static func captureWindow(_ window: NSWindow, to url: URL) async {
        window.makeKeyAndOrderFront(nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do {
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            try process.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { throw ValidationError("Window capture timed out.") }
            process.waitUntilExit()
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let png = try file.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
            guard process.terminationStatus == 0, png.count > 1000, png.count <= 8 * 1024 * 1024,
                  png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw ValidationError("Window capture was unavailable.") }
            trace("Native window OS capture saved: \(url.lastPathComponent)")
        } catch {
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(for: .milliseconds(250))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            // Recording permission depends on the runner. Keep the renderer assertions;
            // never grant recording access or alter the runner's privacy settings here.
            trace("Native window OS capture unavailable: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
        }
    }
    private static func evaluate(_ tab: ChromiumTab, _ source: String, timeout: Duration = .seconds(15)) async throws -> String {
        let data = try await tab.request("Runtime.evaluate", parameters: ["expression": source, "returnByValue": true], timeout: timeout)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = response["result"] as? [String: Any], let value = result["value"] as? String else {
            throw ValidationError("The Chromium script did not return its expected result.")
        }
        return value
    }
    private struct ChromeContents: Decodable {
        struct Page: Decodable { let id: Int; let url: String; let active: Bool }
        let browsers: [Page]
        let activeBrowser: Int
        var ids: Set<Int> { Set(browsers.map(\.id)) }
    }
    private static func chromeContents(_ tab: ChromiumTab) async throws -> ChromeContents {
        let data = try await tab.request("Neutrino.chromeHostState", parameters: [:], timeout: .seconds(3))
        let state = try JSONDecoder().decode(ChromeContents.self, from: data)
        guard state.browsers.filter(\.active).count == 1,
              state.browsers.contains(where: { $0.id == state.activeBrowser && $0.active }) else {
            throw ValidationError("Chromium did not identify its actual active browser.")
        }
        return state
    }
    private static func verifyPopupDocument(_ tab: ChromiumTab, property: String?, token: String, title: String, submittedBody: String? = nil) async throws {
        let popupExpression = property.map { "source && source.\($0)" } ?? "window"
        let expression = """
        (() => {
          const source = window.neutrinoPopupToken === '\(token)' ? window : window.opener;
          const popup = \(popupExpression);
          if (!popup || popup.closed) return '';
          const doc = popup.document;
          return JSON.stringify({
            title: doc.title, body: doc.body ? doc.body.innerText : '',
            exactOpener: popup === window && popup.opener === source,
            openerAbsent: popup.opener === null,
            openerToken: popup.opener && popup.opener.neutrinoPopupToken,
            cookie: doc.cookie,
            method: doc.getElementById('request-method')?.textContent,
            submittedBody: doc.getElementById('submitted-body')?.textContent
          });
        })()
        """
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var lastDocument = "unavailable"
        while ContinuousClock.now < deadline {
            if let value = try? await evaluate(tab, expression, timeout: .seconds(3)) {
                lastDocument = value
                if let data = value.data(using: .utf8),
                   let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   document["title"] as? String == title,
                   (document["cookie"] as? String)?.contains("neutrinoPopupProof=\(token)") == true {
                    let openerMatches = property == nil
                        ? document["openerAbsent"] as? Bool == true
                        : document["exactOpener"] as? Bool == true && document["openerToken"] as? String == token
                    guard openerMatches else { throw ValidationError("The popup's opener policy changed: \(value).") }
                    if let submittedBody {
                        if document["method"] as? String == "POST", document["submittedBody"] as? String == submittedBody { return }
                    } else if document["body"] as? String == "Popup" { return }
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError("The actual Chromium popup did not preserve its document, opener policy, profile cookie, or POST body: \(lastDocument).")
    }
    private static func verifyPopups(in browser: BrowserModel, app: AppState) async throws {
        let parentID = browser.session.selectedTabID
        let outerIDs = browser.session.tabs.map(\.id)
        guard let parent = browser.activeWebTab as? ChromiumTab,
              let expectedWindow = parent.nativeView.window, let chromeWindow = parent.chromeWindow else {
            throw ValidationError("The popup probe requires a hosted Chromium pane.")
        }
        let profileID = parent.profileID, privateSessionID = parent.privateSessionID
        let runtime = ChromiumRuntime.shared
        let existingPopups = runtime.auxiliaryTabs
        let existingPopupIDs = Set(existingPopups.map(ObjectIdentifier.init))
        let originalContents = try await chromeContents(parent)
        let originalDocument = try await evaluate(parent, "JSON.stringify({href: location.href, title: document.title})")
        let token = UUID().uuidString
        _ = try await evaluate(parent, "window.neutrinoPopupToken = '\(token)'; document.cookie = 'neutrinoPopupProof=\(token); path=/'; String(window.neutrinoPopupToken)")
        func newPopups() -> [ChromiumTab] {
            runtime.auxiliaryTabs.filter {
                !existingPopupIDs.contains(ObjectIdentifier($0)) &&
                $0.profileID == profileID && $0.privateSessionID == privateSessionID
            }
        }
        defer { for popup in newPopups() { popup.dispose() } }
        func verifyPaneOwnership() async throws {
            let contents = try await chromeContents(parent)
            guard browser.session.selectedTabID == parentID, browser.session.tabs.map(\.id) == outerIDs,
                  browser.activeWebTab === parent, parent.nativeView.window === expectedWindow,
                  parent.chromeWindow === chromeWindow, chromeWindow.parent === expectedWindow,
                  chromeWindow.isVisible, expectedWindow.isVisible,
                  parent.profileID == profileID, parent.privateSessionID == privateSessionID,
                  contents.ids == originalContents.ids, contents.activeBrowser == originalContents.activeBrowser else {
                throw ValidationError("A native popup changed its originating Neutrino pane, browser, profile, or window.")
            }
        }
        func waitForPopup(_ stage: String) async throws -> ChromiumTab {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            var observed = "no auxiliary window"
            while ContinuousClock.now < deadline {
                let candidates = newPopups()
                observed = candidates.map { "window=\($0.chromeWindow?.windowNumber ?? -1),visible=\($0.chromeWindow?.isVisible == true),url=\($0.url?.absoluteString ?? "nil")" }.joined(separator: "; ")
                if candidates.count == 1, let popup = candidates.first,
                   let window = popup.chromeWindow, window !== chromeWindow, window !== expectedWindow, window.isVisible,
                   let contents = try? await chromeContents(popup), contents.ids.count == 1,
                   contents.ids.isDisjoint(with: originalContents.ids) {
                    try await verifyPaneOwnership()
                    trace("Popup acceptance: \(stage) adopted native window \(window.windowNumber), browsers \(contents.ids.sorted()), private=\(privateSessionID != nil)")
                    return popup
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ValidationError("The \(stage) popup did not become an owned native Chrome window (observed: \(observed)).")
        }
        func closePopup(_ popup: ChromiumTab, property: String?) async throws {
            let windowID = popup.chromeWindow?.windowNumber ?? -1
            if let property {
                _ = try await evaluate(parent, "window.\(property).close(); 'closing'", timeout: .seconds(3))
            } else {
                // A target=_blank form defaults to noopener. Close its actual
                // script-created window; destruction can cancel this response.
                _ = try? await evaluate(popup, "window.close(); 'closing'", timeout: .seconds(3))
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while runtime.auxiliaryTabs.contains(where: { $0 === popup }) || popup.chromeWindow != nil {
                guard ContinuousClock.now < deadline else {
                    throw ValidationError("Popup window \(windowID) did not deliver its native CLOSED callback after its JavaScript close request.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await verifyPaneOwnership()
            guard try await evaluate(parent, "JSON.stringify({href: location.href, title: document.title})") == originalDocument,
                  try await evaluate(parent, "String(window.neutrinoPopupToken)") == token else {
                throw ValidationError("Closing a Chrome popup did not preserve its original live document.")
            }
            trace("Popup acceptance: window \(windowID) closed; original native browsers \(originalContents.ids.sorted()) remain")
        }
        let originalPolicy = app.library.preferences.blockPopups
        defer {
            app.library.preferences.blockPopups = originalPolicy
            browser.updatePopupPolicy()
        }
        app.library.preferences.blockPopups = true; browser.updatePopupPolicy()
        let blocked = try await evaluate(parent, "(() => { const w = window.open('about:blank'); if (w) { w.close(); return 'opened'; } return 'blocked'; })()")
        guard blocked == "blocked" else { throw ValidationError("Chromium opened an unsolicited popup while Neutrino blocks popups.") }
        try await Task.sleep(for: .milliseconds(250))
        guard newPopups().isEmpty else { throw ValidationError("A blocked popup created a native Chrome window.") }
        try await verifyPaneOwnership()
        app.library.preferences.blockPopups = false; browser.updatePopupPolicy()
        // CEF's lifespan popup handler preserves the original WebContents in a
        // new native Chrome window, even for NEW_FOREGROUND_TAB disposition.
        // Inspect that owned auxiliary; never reopen its URL or force a tab move.
        trace("Popup acceptance: opening an allowed blank popup")
        _ = try? await evaluate(parent, "(() => { const w = window.open('about:blank'); if (!w) return 'blocked'; window.neutrinoPopupHandle = w; w.document.write('<html><title>Neutrino Chromium popup</title><body>Popup</body></html>'); w.document.close(); return 'opened'; })()", timeout: .seconds(3))
        let blank = try await waitForPopup("blank")
        try await verifyPopupDocument(blank, property: "neutrinoPopupHandle", token: token, title: "Neutrino Chromium popup")
        try await closePopup(blank, property: "neutrinoPopupHandle")
        // A target=_blank form defaults to noopener. Verify the submitted
        // document directly, including that isolation and its real POST/cookie.
        trace("Popup acceptance: submitting the original target=_blank POST")
        _ = try? await evaluate(parent, "(() => { delete window.neutrinoPostPopup; const form = document.querySelector('form[action=\"/submitted\"]'); if (!form) return 'missing form'; form.submit(); return 'submitted'; })()", timeout: .seconds(3))
        let submitted = try await waitForPopup("POST")
        try await verifyPopupDocument(submitted, property: nil, token: token, title: "Neutrino POST fixture", submittedBody: "test=preserved")
        guard (try await chromeContents(submitted)).browsers.contains(where: { URL(string: $0.url)?.path == "/submitted" }) else {
            throw ValidationError("The submitted document was not the newly created native Chrome browser.")
        }
        try await closePopup(submitted, property: nil)
        _ = try await evaluate(parent, "document.cookie = 'neutrinoPopupProof=; path=/; max-age=0'; delete window.neutrinoPopupToken; delete window.neutrinoPopupHandle; delete window.neutrinoPostPopup; 'cleaned'")
    }
    private static func openProbe(app: AppState, privateBrowsing: Bool, profileID: UUID?, address: String) async throws -> (BrowserModel, NSWindow) {
        let model = BrowserModel(app: app, isPrivate: privateBrowsing)
        if let profileID { model.changeProfile(profileID) }
        model.changeEngine(model.session.selectedTabID, to: .chromium)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserWindow(model: model).environmentObject(app))
        window.orderFront(nil); model.navigate(address)
        do {
            let deadline = Date().addingTimeInterval(15)
            while model.activeWebTab.title != "Neutrino HTTP fixture" || model.activeWebTab.loading {
                if let error = model.activeWebTab.errorMessage { throw ValidationError(error) }
                if Date() > deadline { throw ValidationError("A Chromium isolation page did not load.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            return (model, window)
        } catch { model.closeWindow(); window.close(); throw error }
    }
    private static func measureIdle(_ phase: String) async throws {
        guard ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_PERFORMANCE"] == "1" else { return }
        trace("SMOKE_PERFORMANCE_IDLE_BEGIN \(phase)")
        try await Task.sleep(for: .seconds(5))
        trace("SMOKE_PERFORMANCE_IDLE_END \(phase)")
    }
    private static func trace(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }
    private static func fail(_ message: String) {
        trace("Neutrino smoke test failed: \(message)")
        exit(1)
    }
}
