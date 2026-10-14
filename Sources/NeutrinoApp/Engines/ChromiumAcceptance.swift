// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import NeutrinoCore

/// Executed only by the packaged application's isolated native smoke test.
@MainActor
enum ChromiumAcceptance {
    static func verifyExtensionInterface(browser: BrowserModel, ownerWindow: NSWindow) async throws {
        guard ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_DATA"] != nil,
              CommandLine.arguments.contains("--smoke-test"), !browser.app.finalQuitDataFrozen else {
            throw ValidationError("Extension interface acceptance requires the isolated smoke-test launch.")
        }
        let shell = try await RustShellAcceptance.waitForShell(in:ownerWindow)
        let originalProfile = browser.session.profileID
        browser.endSplit()
        func openManager() async throws -> ChromiumTab {
            try await RustShellAcceptance.action(["op":"screen","value":"extensions"],web:shell)
            _ = try await shell.evaluateJavaScript("document.querySelector('[data-op=installExtension]').click()")
            let deadline = ContinuousClock.now.advanced(by:.seconds(15))
            while ContinuousClock.now < deadline {
                if let page = browser.activeWebTab as? ChromiumTab,
                   page.url?.scheme == "chrome", page.url?.host == "extensions", !page.loading,
                   page.nativeView.window === ownerWindow, page.chromeWindow?.isVisible == true {
                    guard page.profileID == browser.session.profileID else { throw ValidationError("The extension manager used another Profile.") }
                    try await verifyChromeGeometry(page,ownerWindow:ownerWindow)
                    return page
                }
                try await Task.sleep(for:.milliseconds(100))
            }
            throw ValidationError("The extension manager did not open in a Neutrino tab.")
        }
        func closeManager(_ page:ChromiumTab,id:UUID) async throws {
            _ = try? await page.request("Page.close",parameters:[:],timeout:.seconds(5))
            let deadline = ContinuousClock.now.advanced(by:.seconds(10))
            while browser.session.tabs.contains(where:{$0.id == id}) {
                guard ContinuousClock.now < deadline else { throw ValidationError("Chrome did not close its Neutrino manager tab.") }
                try await Task.sleep(for:.milliseconds(50))
            }
            guard ownerWindow.isVisible,ownerWindow.attachedSheet == nil else { throw ValidationError("Closing the extension manager disrupted its browser window.") }
        }
        let original = try await openManager(), originalID = browser.session.selectedTabID
        let profile = Profile(name:"Extension profile acceptance")
        browser.app.library.profiles.append(profile)
        guard browser.app.createSpace(name:profile.name,profileID:profile.id) != nil else { throw ValidationError("The extension acceptance Profile has no Space.") }
        try await RustShellAcceptance.action(["op":"native","action":"switchProfile","id":profile.id.uuidString],web:shell)
        let replacement = try await openManager()
        guard replacement !== original, original.chromeWindow?.isVisible != true else { throw ValidationError("Switching Profiles exposed the previous extension manager.") }
        try await closeManager(replacement,id:browser.session.selectedTabID)
        try await RustShellAcceptance.action(["op":"native","action":"switchProfile","id":originalProfile.uuidString],web:shell)
        browser.selectTab(originalID)
        guard browser.activeWebTab === original else { throw ValidationError("Returning to the original Profile replaced its extension manager document.") }
        try await closeManager(original,id:originalID)
        _ = try await openManager() // Leave a real manager tab open for normal Quit.
        print("Neutrino Chromium acceptance: Rust extension controls, Profile isolation, retained manager, engine close and quit ownership passed")
    }
    static func verifyKeyboardRouting(browser: BrowserModel, ownerWindow: NSWindow) async throws {
        guard CommandLine.arguments.contains("--smoke-test"),
              let address = ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_URL"],
              let url = URL(string: address), url.host == "127.0.0.1" else {
            throw ValidationError("Keyboard acceptance requires the isolated loopback fixture.")
        }
        let original = browser.session.selectedTabID
        let ids = Set(browser.session.tabs.map(\.id))
        let oldEngine = browser.profile.engineID
        if let i = browser.app.library.profiles.firstIndex(where: { $0.id == browser.profile.id }) { browser.app.library.profiles[i].engineID = .chromium }
        defer {
            for id in browser.session.tabs.map(\.id) where !ids.contains(id) { browser.closeTab(id) }
            browser.selectTab(original)
            browser.shellAction?(["op":"screen","value":"browse"])
            if let i = browser.app.library.profiles.firstIndex(where: { $0.id == browser.profile.id }) { browser.app.library.profiles[i].engineID = oldEngine }
        }
        func wait(_ label:String,_ condition: () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !(try await condition()) { guard ContinuousClock.now < deadline else { throw ValidationError("Neutrino keyboard routing timed out: \(label), tabs=\(browser.session.tabs.count), visible=\(ownerWindow.isVisible), closed=\(browser.isClosed).") }; try await Task.sleep(for: .milliseconds(50)) }
        }
        browser.newTab(url: url, engine: .chromium)
        let probe = browser.session.selectedTabID
        let page = try requireChromium(browser.activeWebTab)
        try await wait("fixture mount") { page.url == url && !page.loading && page.chromeWindow?.isVisible == true }
        try await verifyChromeGeometry(page, ownerWindow: ownerWindow)
        _ = try await evaluate(page, "(window.neutrinoLiveMarker=73, 'ready')")
        let count = browser.session.tabs.count
        page.focus()
        try key("t", code: 17, modifiers: .command, window: page.chromeWindow!)
        try await wait("Command-T") { browser.session.tabs.count == count + 1 }
        guard browser.session.selectedTabID != probe else { throw ValidationError("Command-T did not create a Neutrino tab.") }
        try key("w", code: 13, modifiers: .command, window: ownerWindow)
        try await wait("Command-W") { browser.session.tabs.count == count && ownerWindow.isVisible && !browser.isClosed }
        browser.selectTab(probe)
        guard browser.activeWebTab === page, try await evaluate(page, "String(window.neutrinoLiveMarker)") == "73" else { throw ValidationError("Creating and closing a tab replaced the existing document.") }
        page.focus()
        try key("l", code: 37, modifiers: .command, window: page.chromeWindow!)
        let shell = try await RustShellAcceptance.waitForShell(in:ownerWindow)
        let addressDeadline = ContinuousClock.now.advanced(by:.seconds(15))
        while true {
            let responder = ownerWindow.firstResponder as? NSView
            let nativeFocus = ownerWindow.isKeyWindow && (responder === shell || responder?.isDescendant(of:shell) == true)
            let addressFocus = (try await shell.evaluateJavaScript("document.activeElement?.id === 'address-input'")) as? Bool == true
            if nativeFocus && addressFocus { break }
            guard ContinuousClock.now < addressDeadline else { throw ValidationError("Command-L did not focus Neutrino’s address field in its native Rust shell.") }
            try await Task.sleep(for:.milliseconds(50))
        }
        guard !page.hasNativeNavigationChrome else { throw ValidationError("Chrome's native toolbar remains active.") }
        // Location stays inline. Quick navigation is the explicit popup command.
        page.focus()
        try key("k",code:40,modifiers:.command,window:page.chromeWindow!)
        try await wait("Command-K quick navigation") {
            (try await shell.evaluateJavaScript("document.activeElement?.id==='command-input' && !!document.querySelector('.command-palette')")) as? Bool == true
        }
        try key("\u{1b}",code:53,window:ownerWindow)
        try await wait("quick navigation dismissal") {
            (try await shell.evaluateJavaScript("!document.querySelector('.command-palette')")) as? Bool == true
        }
        try await wait("page remount after quick navigation") { page.chromeWindow?.parent === ownerWindow && page.chromeWindow?.isVisible == true }
        try await RustShellAcceptance.action(["op":"native","action":"toggleFocus"],web:shell)
        guard browser.focusMode else { throw ValidationError("Focus provider did not enter Focus mode.") }
        page.focus()
        try await wait("website focus during Focus mode") { page.chromeWindow?.isKeyWindow == true }
        try key("\u{1b}",code:53,window:page.chromeWindow!)
        try await wait("Escape restores Focus from the website") { !browser.focusMode }
        guard try await evaluate(page,"String(window.neutrinoLiveMarker)")=="73" else { throw ValidationError("Focus changed the live document.") }
        func performMenuItem(_ title: String, in menu: NSMenu) -> Bool {
            menu.update()
            for (index, item) in menu.items.enumerated() {
                if item.title == title, item.isEnabled { menu.performActionForItem(at: index); return true }
                if let submenu = item.submenu, performMenuItem(title, in: submenu) { return true }
            }
            return false
        }
        func performWhenReady(_ title:String) async throws {
            let deadline = ContinuousClock.now.advanced(by:.seconds(5))
            repeat {
                if let menu = NSApp.mainMenu, performMenuItem(title,in:menu) { return }
                try await Task.sleep(for:.milliseconds(50))
            } while ContinuousClock.now < deadline
            var inventory:[String] = []
            func describe(_ menu:NSMenu) {
                for item in menu.items where inventory.count < 128 {
                    inventory.append("\(item.identifier?.rawValue ?? "-"):\(item.title),enabled=\(item.isEnabled),target=\(item.target.map { String(describing:type(of:$0)) } ?? "nil"),action=\(item.action.map(NSStringFromSelector) ?? "nil")")
                    if let submenu = item.submenu { describe(submenu) }
                }
            }
            if let menu = NSApp.mainMenu { describe(menu) }
            throw ValidationError("Neutrino \(title) menu unavailable: key=\(NSApp.keyWindow?.windowNumber ?? -1), parent=\(NSApp.keyWindow?.parent?.windowNumber ?? -1), menu=\(inventory.joined(separator:"; "))")
        }
        page.focus()
        try await wait("page focus before File menu") { page.chromeWindow?.isKeyWindow == true }
        try await performWhenReady("New tab")
        try await wait("New tab menu") { browser.session.tabs.count == count + 1 }
        try await performWhenReady("Close tab")
        try await wait("Close tab menu") { browser.session.tabs.count == count }
        browser.selectTab(probe)
        guard browser.activeWebTab === page, try await evaluate(page, "String(window.neutrinoLiveMarker)") == "73" else { throw ValidationError("File-menu tab actions replaced the existing document.") }
        try await verifyNavigationRetry(browser: browser, tab: page, fixtureURL: url)
        try await verifySingleTabRecoveryAndDownload(app: browser.app, fixtureURL: url)
        print("Neutrino Chromium acceptance: custom tab creation/close, retained document, and Neutrino address focus passed")
    }
    private static func requireChromium(_ tab: BrowserEngineTab) throws -> ChromiumTab {
        guard let tab = tab as? ChromiumTab else { throw ValidationError("Blink is unavailable.") }; return tab
    }
    private static func verifyNavigationRetry(browser: BrowserModel, tab: ChromiumTab, fixtureURL: URL) async throws {
        browser.showStartPage()
        try await waitForStartPage(tab)
        var targetComponents = URLComponents(url: fixtureURL, resolvingAgainstBaseURL: false)
        targetComponents?.path = "/navigation-retry"
        guard let target = targetComponents?.url else { throw ValidationError("The navigation recovery fixture URL is invalid.") }
        // Bypass the adapter's load method, as an extension can. The fixture
        // closes the connection without a response until recovery is enabled.
        _ = try await tab.request("Page.navigate", parameters: ["url": target.absoluteString])
        let failureDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while tab.errorMessage == nil || tab.loading {
            guard ContinuousClock.now < failureDeadline else { throw ValidationError("Chromium did not report the fixture's failed HTTP navigation.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !tab.isShowingStartPage, tab.url == target, browser.hasPage, browser.activeWebTab === tab,
              browser.selectedTab.url == target, browser.address == target.absoluteString else {
            throw ValidationError("A failed Chromium navigation lost its requested address behind the native start page (target=\(target), engineURL=\(tab.url?.absoluteString ?? "nil"), selectedURL=\(browser.selectedTab.url?.absoluteString ?? "nil"), address=\(browser.address), editing=\(browser.addressEditing), hasPage=\(browser.hasPage), sameAdapter=\(browser.activeWebTab === tab), startPage=\(tab.isShowingStartPage), ready=\(tab.isReadyForEngineSwitch), loading=\(tab.loading), error=\(tab.errorMessage ?? "nil")).")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: URLRequest(url: target.appendingPathComponent("enable"), timeoutInterval: 5))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ValidationError("The navigation recovery fixture could not be enabled.") }
        tab.reload()
        try await waitForLoad(tab, host: "127.0.0.1")
        guard tab.url == target, tab.errorMessage == nil, !tab.isShowingStartPage,
              try await evaluate(tab, "location.href") == target.absoluteString else {
            throw ValidationError("Chromium Retry did not load the failed web address after its server recovered.")
        }
        print("Neutrino Chromium acceptance: Home failure retained its address and native Retry loaded the recovered HTTP page")
    }
    private static func waitForStartPage(_ tab: ChromiumTab) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var document = ""
        while ContinuousClock.now < deadline {
            if !tab.loading {
                document = (try? await evaluate(tab, "location.href")) ?? ""
                if document == "about:blank", tab.isShowingStartPage,
                   !tab.hasNativeNavigationChrome, !tab.loading { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError("Blink Home did not restore Neutrino's start surface (document=\(document), loading=\(tab.loading)).")
    }
    private static func nativeBrowsers(_ tab: ChromiumTab) async throws -> [[String: Any]] {
        let data = try await tab.request("Neutrino.chromeHostState", parameters: [:])
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let members = value["browsers"] as? [[String: Any]] else {
            throw ValidationError("The normal Chrome pane did not report its owned inner browsers.")
        }
        return members
    }
    private static func verifyNativeTabMenus(_ tab: ChromiumTab) async throws {
        try await focusPage(tab)
        let before = try await nativeBrowsers(tab)
        let ids = Set(before.compactMap { $0["id"] as? Int })
        func perform(_ title: String, in menu: NSMenu) -> Bool {
            menu.update()
            for (index, item) in menu.items.enumerated() {
                if item.title == title, item.isEnabled { menu.performActionForItem(at: index); return true }
                if let submenu = item.submenu, perform(title, in: submenu) { return true }
            }
            return false
        }
        func performWhenReady(_ title: String) async throws -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            repeat {
                if let menu = NSApp.mainMenu, perform(title, in: menu) { return true }
                try await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            return false
        }
        guard try await performWhenReady("New tab") else {
            var items: [[String: Any]] = []
            func describe(_ menu: NSMenu) {
                for item in menu.items where items.count < 128 {
                    items.append(["title":item.title, "enabled":item.isEnabled,
                                  "action":item.action.map(NSStringFromSelector) ?? "nil",
                                  "target":item.target.map { String(describing: type(of: $0)) } ?? "nil"])
                    if let submenu = item.submenu { describe(submenu) }
                }
            }
            if let menu = NSApp.mainMenu { describe(menu) }
            let inventory = (try? JSONSerialization.data(withJSONObject: items)).map { String(decoding: $0, as: UTF8.self) } ?? "unavailable"
            print("Neutrino Chromium native menu unavailable: key=\(NSApp.keyWindow?.windowNumber ?? -1), main=\(NSApp.mainWindow?.windowNumber ?? -1), auxiliary=\(tab.isAuxiliary), focusedOwner=\(ChromiumRuntime.shared.focusedNativeTab === tab), menu=\(inventory)")
            throw ValidationError("The actual Neutrino New tab menu was unavailable with a native Chrome window focused.")
        }
        let addDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try await nativeBrowsers(tab).count != before.count + 1 {
            guard ContinuousClock.now < addDeadline else { throw ValidationError("The native New tab menu did not target the focused Chrome pane.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard try await performWhenReady("Close tab") else { throw ValidationError("The actual Neutrino Close tab menu was unavailable for Chrome.") }
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while Set(try await nativeBrowsers(tab).compactMap { $0["id"] as? Int }) != ids {
            guard ContinuousClock.now < closeDeadline else { throw ValidationError("The native Close tab menu closed the wrong Chrome pane or inner tab.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("Neutrino Chromium acceptance: actual New/Close menu routed to focused \(tab.isAuxiliary ? "auxiliary" : "embedded") native Chrome window")
    }
    private static func verifySingleTabRecoveryAndDownload(app: AppState, fixtureURL: URL) async throws {
        let downloads = DownloadCenter()
        let directory = app.dataDirectory.appendingPathComponent("DownloadAcceptance", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("neutrino-download-fixture.bin")
        try downloads.useAcceptanceDestination(destination)
        let restored = try ChromiumRuntime.shared.makeTab(profileID: UUID(), privateSessionID: nil, dataDirectory: app.dataDirectory, downloads: downloads)
        let window = NSWindow(contentRect: NSRect(x: 160, y: 120, width: 900, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = restored.nativeView
        window.makeKeyAndOrderFront(nil)
        defer { restored.dispose(); window.close() }
        restored.restoreChromiumSessionPages([ChromiumSessionPage(url: fixtureURL)])
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while restored.chromiumSessionPages?.count != 1 || restored.url != fixtureURL || restored.loading {
            guard ContinuousClock.now < deadline else { throw ValidationError("A saved Neutrino Blink tab did not restore its selected website.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard try await evaluate(restored, "location.href") == fixtureURL.absoluteString else {
            throw ValidationError("Blink restored the wrong document.")
        }
        _ = try await evaluate(restored, "(document.documentElement.dataset.neutrinoActiveCapture='restored-tab', 'ready')")
        guard try await restored.pageHTML().contains("neutrino-active-capture=\"restored-tab\""), !(try await restored.capturePNG()).isEmpty else { throw ValidationError("Reader or Capture targeted the wrong restored document.") }
        guard let address = ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_URL"],
              var sourceComponents = URLComponents(string: address) else {
            throw ValidationError("The isolated slow download fixture is unavailable.")
        }
        sourceComponents.path = "/slow-download"
        guard let source = sourceComponents.url else { throw ValidationError("The isolated slow download fixture URL is invalid.") }
        let sourceJSON = String(decoding: try JSONSerialization.data(withJSONObject: source.absoluteString, options: [.fragmentsAllowed]), as: UTF8.self)
        _ = try await evaluate(restored, "(function(){ const a=document.createElement('a'); a.href=\(sourceJSON); a.download='neutrino-download-fixture.bin'; document.body.append(a); a.click(); return 'started'; })()")
        let transferDeadline = ContinuousClock.now.advanced(by: .seconds(8))
        while downloads.items.first?.staging == nil || downloads.items.first?.fraction == 0 {
            guard ContinuousClock.now < transferDeadline else { throw ValidationError("Chromium did not begin the real slow download.") }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let transfer = downloads.items.first, let staging = transfer.staging, !transfer.transferEnded,
              FileManager.default.fileExists(atPath: staging.path) else {
            throw ValidationError("The slow Chromium transfer did not own a staging file.")
        }
        var closed = false
        restored.onClose = { closed = true }
        _ = try? await restored.request("Page.close", parameters: [:], timeout: .seconds(5))
        let lastCloseDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !closed {
            guard ContinuousClock.now < lastCloseDeadline else { throw ValidationError("A tab's download prevented its page from closing.") }
            try await Task.sleep(for: .milliseconds(50))
        }
        try verifyClosedDownload(transfer, staging: staging, downloads: downloads)
        // The external smoke runner verifies this file is gone after normal
        // Quit, which executes the actual CefShutdown and registry cleanup.
        try staging.path.write(to: directory.appendingPathComponent("expected-staging.txt"), atomically: true, encoding: .utf8)
        print("Neutrino Chromium acceptance: tab recovery, Reader/Capture and download close passed; terminalConfirmed=\(transfer.transferEnded), pendingShutdown=\(downloads.hasShutdownPendingDownloads)")
    }
    private static func verifyClosedDownload(_ transfer: DownloadItem, staging: URL, downloads: DownloadCenter) throws {
        let exists = FileManager.default.fileExists(atPath: staging.path)
        // Chrome can acknowledge cancellation before OnBeforeClose, or lose
        // its callback owner first. Cleanup requires a real terminal update
        // or successful engine shutdown; pane destruction alone is insufficient.
        if transfer.transferEnded {
            guard !exists else { throw ValidationError("A terminally acknowledged native download retained its staging file.") }
        } else {
            // Chrome may remove its own cancelled file without delivering
            // another CEF callback. Neutrino must retain ownership of that path
            // and await shutdown, regardless of the engine's file disposition.
            guard transfer.acknowledgementUnavailable, transfer.staging == staging,
                  downloads.hasShutdownPendingDownloads else {
                throw ValidationError("The unconfirmed native writer lost shutdown ownership (ownerClosed=\(transfer.acknowledgementUnavailable), status=\(transfer.status), stagingOwned=\(transfer.staging == staging), pendingShutdown=\(downloads.hasShutdownPendingDownloads)).")
            }
        }
    }
    private static func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
                throw ValidationError("AppKit could not create the owned-window keyboard event.")
            }
            // Enter AppKit's own event queue so local monitors and key
            // equivalents run through the same dispatch path as user input.
            NSApp.postEvent(event, atStart: false)
        }
    }
    static func verifyChromeGeometry(_ tab: ChromiumTab, ownerWindow: NSWindow) async throws {
        guard let chrome = tab.chromeWindow else { throw ValidationError("Chrome has no native window.") }
        let buttonKinds = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
        let controls = buttonKinds.map { kind -> String in
            guard let button = chrome.standardWindowButton(kind) else { return "\(kind.rawValue):missing" }
            return "\(kind.rawValue):hidden=\(button.isHidden),enabled=\(button.isEnabled),window=\(button.window?.windowNumber ?? -1),super=\(button.superview.map { String(describing: type(of: $0)) } ?? "nil")"
        }.joined(separator: "; ")
        let frameState = "style=\(chrome.styleMask.rawValue),behavior=\(chrome.collectionBehavior.rawValue),movable=\(chrome.isMovable),backgroundMovable=\(chrome.isMovableByWindowBackground),buttons=[\(controls)]"
        guard !chrome.isMovable, !chrome.isMovableByWindowBackground,
              chrome.collectionBehavior.contains(.fullScreenAuxiliary),
              chrome.collectionBehavior.contains(.fullScreenDisallowsTiling) else {
            throw ValidationError("The embedded Chrome window can move independently or lost its required native frame (\(frameState)).")
        }
        for kind in buttonKinds {
            if let button = chrome.standardWindowButton(kind), !button.isHidden || button.isEnabled {
                throw ValidationError("An embedded Chrome window exposes a second set of native window controls (\(frameState)).")
            }
        }
        let expected = ownerWindow.convertToScreen(tab.nativeView.convert(tab.nativeView.bounds.intersection(tab.nativeView.visibleRect), to: nil))
        func region(_ identifier: String, in view: NSView) -> NSView? {
            guard !view.isHidden else { return nil }
            if view.identifier?.rawValue == identifier, !view.bounds.isEmpty { return view }
            for child in view.subviews { if let found = region(identifier, in: child) { return found } }
            return nil
        }
        guard let root = ownerWindow.contentView, let page = tab.nativeView.superview as? EngineViewContainer,
              page.window === ownerWindow, !page.isHidden else {
            throw ValidationError("Neutrino's independent native page layout region is unavailable.")
        }
        let pageRect = ownerWindow.convertToScreen(page.convert(page.bounds, to: nil))
        guard pageRect.insetBy(dx: -2, dy: -2).contains(chrome.frame) else {
            throw ValidationError("Chrome covers controls outside Neutrino's page region (page=\(pageRect), child=\(chrome.frame)).")
        }
        if let tabs = region("neutrino.verticalTabs", in: root) {
            let tabRect = ownerWindow.convertToScreen(tabs.convert(tabs.bounds, to: nil))
            let overlap = chrome.frame.intersection(tabRect)
            guard overlap.isNull || overlap.width < 2 || overlap.height < 2 else {
                throw ValidationError("Chrome overlaps Neutrino's visible native tab strip.")
            }
        }
        let nativeState = try await tab.request("Neutrino.chromeHostState", parameters: [:])
        let state = try JSONSerialization.jsonObject(with: nativeState) as? [String: Any] ?? [:]
        print("Neutrino Chromium geometry: owner=\(ownerWindow.windowNumber) \(ownerWindow.frame), child=\(chrome.windowNumber) \(chrome.frame), parent=\(chrome.parent?.windowNumber ?? -1), hostBounds=\(tab.nativeView.bounds), hostFrame=\(tab.nativeView.frame), superBounds=\(String(describing: tab.nativeView.superview?.bounds)), anchor=\(expected), chrome=\(String(decoding: nativeState, as: UTF8.self))")
        guard chrome !== ownerWindow, chrome.parent === ownerWindow,
              abs(chrome.frame.minX - expected.minX) < 2, abs(chrome.frame.minY - expected.minY) < 2,
              abs(chrome.frame.width - expected.width) < 2, abs(chrome.frame.height - expected.height) < 2 else {
            throw ValidationError("The Chrome window does not fit its native page anchor; see the recorded window frames.")
        }
        guard state["customHost"] as? Bool == true, !tab.hasNativeNavigationChrome,
              state["toolbarPresent"] as? Bool == true, state["toolbarVisible"] as? Bool == false,
              state["toolbarDrawn"] as? Bool == false else {
            throw ValidationError("Chrome’s native toolbar is visible inside Neutrino’s page surface.")
        }
    }
    static func verifyHostAndManagement(_ tab: ChromiumTab, app: AppState, ownerWindow: NSWindow) async throws {
        guard ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_DATA"] != nil,
              ProcessInfo.processInfo.arguments.contains("--smoke-test") else {
            throw ValidationError("Chromium acceptance requires the isolated smoke-test launch.")
        }
        var failures: [String] = []
        do {
            // The preceding independent keyboard probe restores the selected tab.
            // SwiftUI must remount that tab before inspecting its attached child.
            let mountDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while tab.chromeWindow?.parent !== ownerWindow {
                guard ContinuousClock.now < mountDeadline else { throw ValidationError("The restored Chromium tab did not remount inside its Neutrino window.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard tab.chromeStyle, !tab.hasNativeNavigationChrome, let child = tab.chromeWindow, child !== ownerWindow,
                  child.parent === ownerWindow, child.isVisible else {
                throw ValidationError("Chromium is not an intact Chrome-style child window in Neutrino.")
            }
            try await verifyChromeGeometry(tab, ownerWindow: ownerWindow)
            tab.focus()
            try await Task.sleep(for: .milliseconds(100))
            guard child.isKeyWindow else { throw ValidationError("The Chrome toolbar cannot receive keyboard focus.") }
        } catch { failures.append("Native hosting: " + error.localizedDescription) }
        let manager = try ChromiumRuntime.shared.makeTab(profileID: UUID(), privateSessionID: nil, dataDirectory: app.dataDirectory)
        let managerWindow = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 680),
                                     styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        managerWindow.isReleasedWhenClosed = false
        managerWindow.title = "Neutrino extension acceptance"
        managerWindow.contentView = manager.nativeView
        managerWindow.makeKeyAndOrderFront(nil)
        defer { manager.dispose(); managerWindow.close() }
        manager.showExtensions()
        try await waitForManager(manager)
        let installed = try await evaluate(manager, "JSON.stringify(await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true, includeTerminated:true}))")
        guard let data = installed.data(using: .utf8), (try JSONSerialization.jsonObject(with: data)) is [[String: Any]] else {
            throw ValidationError("The Chrome extension management service did not return installed extensions.")
        }
        guard manager.chromeStyle, manager.chromeWindow?.parent === managerWindow else {
            throw ValidationError("Extension management escaped its native Neutrino window.")
        }
        do { try await verifyFixture(manager, app: app) }
        catch { failures.append("Local MV3 fixture: " + error.localizedDescription) }
        manager.dispose(); managerWindow.close()
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while manager.chromeWindow != nil, ContinuousClock.now < closeDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        if ProcessInfo.processInfo.environment["NEUTRINO_CHROMIUM_WEBSTORE_TEST"] == "1" {
            do {
                // Use a separate profile/window so a local fixture or its own
                // file chooser cannot obscure independent Store evidence.
                let store = try ChromiumRuntime.shared.makeTab(profileID: UUID(), privateSessionID: nil, dataDirectory: app.dataDirectory)
                let storeWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 740),
                                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                storeWindow.isReleasedWhenClosed = false; storeWindow.title = "Neutrino Web Store acceptance"
                storeWindow.contentView = store.nativeView; storeWindow.makeKeyAndOrderFront(nil)
                defer { store.dispose(); storeWindow.close() }
                store.showExtensions(); try await waitForManager(store)
                try await verifyWebStore(store, app: app)
                let version = try await evaluate(store, "String((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).find(e => e.id === 'ddkjiahejlhfcafbddmgiahcphecmpfh')?.version)")
                let receipt: [String: Any] = ["profileID": store.profileID.uuidString, "version": version,
                                              "processID": ProcessInfo.processInfo.processIdentifier]
                try JSONSerialization.data(withJSONObject: receipt).write(
                    to: app.dataDirectory.appendingPathComponent("Chromium/ExtensionAcceptance/webstore-restart.json"), options: .atomic)
            } catch { failures.append("Chrome Web Store: " + error.localizedDescription) }
        }
        if !failures.isEmpty { throw ValidationError(failures.joined(separator: "\n")) }
        print("Neutrino Chromium acceptance: normal Chrome window, native child geometry/focus, and extension manager passed")
    }
    static func verifySessionCookieAfterLastBrowserCloses(app: AppState) async throws {
        var failures: [String] = []
        for isPrivate in [false, true] {
            do { try await verifySessionCookieAfterLastBrowserCloses(app: app, isPrivate: isPrivate) }
            catch { failures.append((isPrivate ? "Private window: " : "Regular profile: ") + error.localizedDescription) }
        }
        if !failures.isEmpty { throw ValidationError(failures.joined(separator: "\n")) }
    }
    private static func verifySessionCookieAfterLastBrowserCloses(app: AppState, isPrivate: Bool) async throws {
        guard ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_DATA"] != nil,
              CommandLine.arguments.contains("--smoke-test"),
              let address = ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_URL"],
              let url = URL(string: address), url.host == "127.0.0.1" else {
            throw ValidationError("The Chromium session-cookie probe requires the loopback fixture.")
        }
        let profile = UUID()
        let privateSessionID = isPrivate ? UUID() : nil
        if let privateSessionID { ChromiumRuntime.shared.beginPrivateSession(privateSessionID) }
        defer { if let privateSessionID { ChromiumRuntime.shared.closePrivateSession(privateSessionID) } }
        let first = try ChromiumRuntime.shared.makeTab(profileID: profile, privateSessionID: privateSessionID, dataDirectory: app.dataDirectory)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 900, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Neutrino session-cookie acceptance"
        window.contentView = first.nativeView; window.makeKeyAndOrderFront(nil)
        defer { first.dispose(); window.close() }
        first.load(url); try await waitForLoad(first, host: "127.0.0.1")
        let cookie = "neutrinoSession" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard try await evaluate(first, "(document.cookie = '\(cookie)=present; path=/', document.cookie)")
            .contains(cookie + "=present") else {
            throw ValidationError("Chromium did not seed an expiry-free session cookie.")
        }
        var closed = false
        first.onClose = { closed = true }
        // Page.close follows Chrome's actual close lifecycle. Disposing the
        // Swift adapter alone only starts asynchronous CEF destruction.
        _ = try? await first.request("Page.close", parameters: [:], timeout: .seconds(5))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !closed {
            guard ContinuousClock.now < deadline else { throw ValidationError("The last Chromium profile browser did not acknowledge closing.") }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard window.isVisible else { throw ValidationError("Closing a Chromium browser also closed its native Neutrino window.") }
        let reopened = try ChromiumRuntime.shared.makeTab(profileID: profile, privateSessionID: privateSessionID, dataDirectory: app.dataDirectory)
        defer { reopened.dispose() }
        window.contentView = reopened.nativeView
        reopened.load(url); try await waitForLoad(reopened, host: "127.0.0.1")
        guard try await evaluate(reopened, "document.cookie").contains(cookie + "=present") else {
            throw ValidationError("Closing the last Chromium browser signed out its website context while its Neutrino window remained open.")
        }
        print("Neutrino Chromium acceptance: expiry-free \(isPrivate ? "private-window" : "regular-profile") cookie survived its last browser closing")
        if let privateSessionID {
            ChromiumRuntime.shared.closePrivateSession(privateSessionID)
            window.close()
            let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while reopened.chromeWindow != nil {
                guard ContinuousClock.now < releaseDeadline else { throw ValidationError("Closing the private window did not finish closing its Chromium browsers.") }
                try await Task.sleep(for: .milliseconds(50))
            }
            // Deliberately reuse the diagnostic identity to prove the released
            // context itself is gone, rather than only testing a different key.
            ChromiumRuntime.shared.beginPrivateSession(privateSessionID)
            let fresh = try ChromiumRuntime.shared.makeTab(profileID: profile, privateSessionID: privateSessionID, dataDirectory: app.dataDirectory)
            let freshWindow = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 900, height: 680),
                                       styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            freshWindow.isReleasedWhenClosed = false
            freshWindow.contentView = fresh.nativeView; freshWindow.makeKeyAndOrderFront(nil)
            defer { fresh.dispose(); freshWindow.close() }
            fresh.load(url); try await waitForLoad(fresh, host: "127.0.0.1")
            guard try await evaluate(fresh, "document.cookie").contains(cookie + "=present") == false else {
                throw ValidationError("A private context kept its sign-in after its native window lifetime ended.")
            }
            print("Neutrino Chromium acceptance: private-window lifetime release erased its session cookie")
        }
    }
    static func verifyStoreRestart(app: AppState) async throws {
        guard ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_DATA"] != nil,
              ProcessInfo.processInfo.environment["NEUTRINO_CHROMIUM_EXTENSION_RESTART"] == "1",
              ProcessInfo.processInfo.arguments.contains("--smoke-test") else {
            throw ValidationError("Extension restart acceptance requires the isolated second smoke-test launch.")
        }
        let receiptURL = app.dataDirectory.appendingPathComponent("Chromium/ExtensionAcceptance/webstore-restart.json")
        let size = try receiptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 4096,
              let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any],
              let profile = receipt["profileID"] as? String, let profileID = UUID(uuidString: profile),
              let version = receipt["version"] as? String,
              let processID = receipt["processID"] as? Int, processID != Int(ProcessInfo.processInfo.processIdentifier) else {
            throw ValidationError("The Web Store restart receipt is missing or was created in this same process.")
        }
        let manager = try ChromiumRuntime.shared.makeTab(profileID: profileID, privateSessionID: nil, dataDirectory: app.dataDirectory)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Neutrino extension restart acceptance"
        window.contentView = manager.nativeView; window.makeKeyAndOrderFront(nil)
        defer { manager.dispose(); window.close() }
        manager.showExtensions(); try await waitForManager(manager)
        let text = try await evaluate(manager, "JSON.stringify((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).find(e => e.id === 'ddkjiahejlhfcafbddmgiahcphecmpfh') || null)")
        guard let data = text.data(using: .utf8), let installed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
              installed["state"] as? String == "ENABLED", installed["version"] as? String == version else {
            throw ValidationError("The Chrome Web Store extension did not persist enabled across the full process restart.")
        }
        try await removeFixtureExtension("ddkjiahejlhfcafbddmgiahcphecmpfh", manager: manager)
        let remains = try await evaluate(manager, "String((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).some(e => e.id === 'ddkjiahejlhfcafbddmgiahcphecmpfh'))")
        guard remains == "false" else { throw ValidationError("The Web Store extension could not be removed after restart.") }
        try FileManager.default.removeItem(at: receiptURL)
        print("Neutrino Chromium acceptance: Web Store extension persisted across a full process restart and was removed")
    }
    private static func removeFixtureExtension(_ id: String, manager: ChromiumTab) async throws {
        guard ["pomncmnnjempbbdlbamhjphmpidacofc", "ddkjiahejlhfcafbddmgiahcphecmpfh"].contains(id) else {
            throw ValidationError("Only the isolated acceptance extensions may be removed by this probe.")
        }
        try await focusPage(manager)
        // Chrome requires native confirmation for removing another extension.
        // Start the real API without awaiting its dialog, then press that
        // specific fixture's owned Remove button and verify the real registry.
        _ = try await evaluate(manager, """
        (() => {
            window.neutrinoFixtureRemoval = 'pending';
            chrome.management.uninstall('\(id)', {showConfirmDialog:true}).then(
                () => window.neutrinoFixtureRemoval = 'removed',
                error => window.neutrinoFixtureRemoval = 'error:' + error.message);
            return 'requested';
        })()
        """)
        var pressDispatched = false
        var nextPress = ContinuousClock.now
        var lastPromptState = ""
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if ContinuousClock.now >= nextPress {
                let response = try await manager.request("Neutrino.removeFixtureExtension", parameters: ["id": id])
                let pressed = (try JSONSerialization.jsonObject(with: response) as? [String: Any])?["pressed"] as? Bool == true
                pressDispatched = pressDispatched || pressed
                // AX reports dispatch even when Chrome's 500 ms input protector
                // rejects a press. A quiet interval allows the same owned
                // fixture dialog to accept the next genuine native action.
                nextPress = ContinuousClock.now.advanced(by: .seconds(1))
                let promptState = String(decoding: response, as: UTF8.self)
                if promptState != lastPromptState {
                    print("Neutrino Chromium native removal prompt: \(promptState)")
                    lastPromptState = promptState
                }
            }
            if pressDispatched {
                let state = try await evaluate(manager, "String(window.neutrinoFixtureRemoval)")
                if state.hasPrefix("error:") { throw ValidationError(state) }
                let remains = try await evaluate(manager, "String((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).some(e => e.id === '\(id)'))")
                let removalState = "callback=\(state), registryContainsFixture=\(remains)"
                if removalState != lastPromptState {
                    print("Neutrino Chromium native removal result: \(removalState)")
                    lastPromptState = removalState
                }
                // The native Remove action and actual profile registry
                // establish removal. The page-local promise flag is diagnostic.
                if remains == "false" {
                    print("Neutrino Chromium acceptance: confirmed the fixture's native Remove dialog and verified registry removal")
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError("The fixture's native Remove dialog or confirmed removal did not finish.")
    }
    private static func waitForManager(_ tab: ChromiumTab) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while tab.url?.scheme != "chrome" || tab.url?.host != "extensions" || tab.loading {
            if let error = tab.errorMessage { throw ValidationError(error) }
            guard ContinuousClock.now < deadline else { throw ValidationError("Chrome extension management did not load.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private static func evaluate(_ tab: ChromiumTab, _ expression: String) async throws -> String {
        let data = try await tab.request("Runtime.evaluate", parameters: [
            "expression": "(async () => { return \(expression); })()", "awaitPromise": true, "returnByValue": true,
            "userGesture": true
        ])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError("Chrome extension acceptance returned invalid JavaScript results.")
        }
        if let exception = object["exceptionDetails"] as? [String: Any] {
            let detail = (exception["exception"] as? [String: Any])?["description"] as? String ?? exception["text"] as? String ?? "Unknown exception"
            throw ValidationError("Chrome extension acceptance JavaScript: \(String(detail.prefix(1200)))")
        }
        guard let result = object["result"] as? [String: Any],
              let value = result["value"] as? String else {
            throw ValidationError("Chrome extension acceptance JavaScript failed.")
        }
        return value
    }
    private static func verifyFixture(_ manager: ChromiumTab, app: AppState) async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_EXTENSION_FIXTURE"],
              let address = ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_URL"],
              let fixtureURL = URL(string: address), fixtureURL.scheme == "http", fixtureURL.host == "127.0.0.1" else {
            throw ValidationError("The isolated extension API fixture is not configured.")
        }
        let id = "pomncmnnjempbbdlbamhjphmpidacofc"
        print("Neutrino Chromium acceptance: loading the isolated native MV3 API fixture")
        let folder = app.dataDirectory.appendingPathComponent("Chromium/ExtensionAcceptance", isDirectory: true)
        let installedFolder = folder.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: installedFolder.path) { try FileManager.default.removeItem(at: installedFolder) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath, isDirectory: true), to: installedFolder)
        _ = try await evaluate(manager, "String(await chrome.developerPrivate.updateProfileConfiguration({inDeveloperMode:true}))")
        try await ChromiumFixtureLoader.load(manager: manager, dataDirectory: app.dataDirectory)
        let enabled = try await evaluate(manager, "String((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).find(e => e.id === '\(id)')?.state)")
        guard enabled == "ENABLED" else { throw ValidationError("The native manager did not load the MV3 fixture.") }
        _ = try await evaluate(manager, "String(await chrome.developerPrivate.updateExtensionConfiguration({extensionId:'\(id)',pinnedToToolbar:true}))")
        let page = try ChromiumRuntime.shared.makeTab(profileID: manager.profileID, privateSessionID: nil, dataDirectory: app.dataDirectory)
        let window = NSWindow(contentRect: NSRect(x: 140, y: 100, width: 1000, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Neutrino MV3 API acceptance"
        window.contentView = page.nativeView; window.makeKeyAndOrderFront(nil)
        defer {
            for auxiliary in ChromiumRuntime.shared.auxiliaryTabs where auxiliary.profileID == manager.profileID { auxiliary.dispose() }
            page.dispose(); window.close()
        }
        page.load(fixtureURL)
        var state = try await waitForFixture(page, key: "neutrinoFixtureWorker", value: "ready")
        guard state["neutrinoFixtureManifestVersion"] == "3", state["neutrinoFixtureScripting"] == "ready",
              state["neutrinoFixtureExtensionId"] == id, let count = Int(state["neutrinoFixtureCount"] ?? "") else {
            throw ValidationError("The MV3 worker, content script, scripting or storage API did not execute.")
        }
        print("Neutrino Chromium acceptance: opening the native extension action and side panel")
        try await click(page, selector: "#neutrino-fixture-action")
        state = try await waitForFixture(page, key: "neutrinoFixtureActionOpened", value: "1")
        guard state["neutrinoFixtureActionState"] != "error" else { throw ValidationError("The extension action did not open.") }
        // Close the action through an ordinary outside click before opening the panel.
        _ = try await page.request("Input.dispatchMouseEvent", parameters: ["type":"mousePressed", "x":20, "y":20, "button":"left", "clickCount":1])
        _ = try await page.request("Input.dispatchMouseEvent", parameters: ["type":"mouseReleased", "x":20, "y":20, "button":"left", "clickCount":1])
        try await click(page, selector: "#neutrino-fixture-sidepanel")
        _ = try await waitForFixture(page, key: "neutrinoFixtureSidePanelOpened", value: "1")
        print("Neutrino Chromium acceptance: MV3 content/worker/scripting/storage/action/side-panel documents executed")

        // Exercise the real management command. Chrome may open an inner tab or
        // an auxiliary window; preserve its actual browser and window identity.
        print("Neutrino Chromium acceptance: opening the native extension settings")
        // Selecting the real options tab can cancel the issuing active-target
        // request. The owned visible document and granted APIs below prove it.
        _ = try? await evaluate(manager, "String(await chrome.developerPrivate.showOptions('\(id)'))")
        let optionsDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        var options: ChromiumTab?
        while ContinuousClock.now < optionsDeadline {
            options = ([manager, page] + ChromiumRuntime.shared.auxiliaryTabs).first { $0.profileID == manager.profileID && $0.url?.host == id && $0.chromeWindow?.isVisible == true }
            if options != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let options else { throw ValidationError("Extension settings did not open in an owned Chrome window.") }
        _ = try await waitForFixture(options, key: "neutrinoFixtureOptionsState", value: "ready")
        guard options.chromeWindow?.isVisible == true else { throw ValidationError("The native extension settings window is not visible.") }
        let permissions = try await evaluate(options, "JSON.stringify(await chrome.permissions.getAll())")
        guard let permissionData = permissions.data(using: .utf8),
              let grants = try JSONSerialization.jsonObject(with: permissionData) as? [String: Any],
              Set(grants["permissions"] as? [String] ?? []).isSuperset(of: ["storage", "activeTab", "scripting", "sidePanel"]),
              (grants["origins"] as? [String] ?? []).contains("http://127.0.0.1/*") else {
            throw ValidationError("The fixture's granted extension permissions differ from its requested scope.")
        }
        try await verifyPristineInactiveTab(options: options, app: app, fixtureURL: fixtureURL)
        try await click(options, selector: "#nativecheckbox")
        _ = try await waitForFixture(options, key: "neutrinoFixtureTheme", value: "dark")
        _ = try await waitForFixture(page, key: "neutrinoFixtureTheme", value: "dark")
        let createdWindowID = try await evaluate(options, "String((await chrome.windows.create({url:chrome.runtime.getURL('options.html?api=window'),type:'normal'})).id)")
        let createdWindow = try await waitForAuxiliary(profileID: manager.profileID, query: "api=window")
        var menuFailure: String?
        let beforeMenu = try await nativeBrowsers(createdWindow)
        do { try await verifyNativeTabMenus(createdWindow) }
        catch {
            let afterMenu = try await nativeBrowsers(createdWindow)
            // Continue independent extension checks only when a failed menu
            // check left the actual window's tabs and selection unchanged.
            guard let active = beforeMenu.first(where: { $0["active"] as? Bool == true })?["id"] as? Int,
                  afterMenu.first(where: { $0["active"] as? Bool == true })?["id"] as? Int == active,
                  Set(beforeMenu.compactMap { $0["id"] as? Int }) == Set(afterMenu.compactMap { $0["id"] as? Int }) else { throw error }
            menuFailure = error.localizedDescription
            print("Neutrino Chromium auxiliary menu: \(error.localizedDescription)")
        }
        let originTabID = try await evaluate(createdWindow, "String((await chrome.tabs.getCurrent()).id)")
        guard try await evaluate(createdWindow, "String((await chrome.windows.getCurrent()).id)") == createdWindowID else {
            throw ValidationError("The extension-created window lost its Chromium window identity.")
        }
        let createdTabID = try await evaluate(createdWindow, "String((await chrome.tabs.create({windowId:Number('\(createdWindowID)'),active:false,url:chrome.runtime.getURL('options.html?api=tab')})).id)")
        guard try await evaluate(createdWindow, "String((await chrome.tabs.getCurrent()).id)") == originTabID,
              try await evaluate(createdWindow, "String((await chrome.tabs.get(Number('\(createdTabID)'))).active)") == "false",
              try await evaluate(createdWindow, "String((await chrome.tabs.get(Number('\(createdTabID)'))).windowId)") == createdWindowID else {
            throw ValidationError("Adopting an inactive extension tab changed its selection or native window identity.")
        }
        let nativeMembers = try await nativeBrowsers(createdWindow)
        guard nativeMembers.count == 2 else { throw ValidationError("The extension's two native tabs were not grouped into one Chrome window.") }
        // Selection can replace the request's active target while the promise
        // completes. Verify the actual committed selected page independently.
        _ = try? await evaluate(createdWindow, "String((await chrome.tabs.update(Number('\(createdTabID)'),{active:true})).id)")
        let selectionDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while createdWindow.url?.query != "api=tab" || createdWindow.loading {
            guard ContinuousClock.now < selectionDeadline else { throw ValidationError("Selecting an extension tab did not update the pane's active WebContents.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard try await evaluate(createdWindow, "String((await chrome.tabs.getCurrent()).id)") == createdTabID else {
            throw ValidationError("Native pane commands still targeted the inactive initial tab.")
        }
        _ = try await evaluate(createdWindow, "(document.documentElement.dataset.neutrinoActiveCapture='extension-tab', 'ready')")
        guard try await createdWindow.pageHTML().contains("neutrino-active-capture=\"extension-tab\"") else {
            throw ValidationError("Reader captured the wrong inner Chrome tab.")
        }
        _ = try await evaluate(createdWindow, "String(!!window.open(chrome.runtime.getURL('options.html?api=popup'),'_blank','popup,width=500,height=420'))")
        let descendant = try await waitForAuxiliary(profileID: manager.profileID, query: "api=popup")
        guard try await evaluate(descendant, "String(!!window.opener)") == "true" else {
            throw ValidationError("An auxiliary popup lost its original opener relationship.")
        }
        _ = try await evaluate(createdWindow, "String(await chrome.tabs.remove(Number('\(originTabID)')))")
        guard try await evaluate(createdWindow, "String((await chrome.tabs.getCurrent()).id)") == createdTabID,
              try await evaluate(createdWindow, "String((await chrome.windows.getCurrent()).id)") == createdWindowID else {
            throw ValidationError("Closing a window's initial browser destroyed its surviving inner tab.")
        }
        // Close only the options WebContents, never its complete owning pane.
        // The originating native manager and its sibling tabs remain usable.
        _ = try? await options.request("Page.close", parameters: [:], timeout: .seconds(5))
        guard try await evaluate(createdWindow, "String((await chrome.tabs.getCurrent()).id)") == createdTabID,
              try await evaluate(descendant, "String(!!window.opener)") == "true" else {
            throw ValidationError("An auxiliary window stopped working after its originating settings tab closed.")
        }
        createdWindow.dispose(); descendant.dispose()
        manager.showExtensions(); try await waitForManager(manager)
        print("Neutrino Chromium acceptance: inactive tabs.create preserved selection/window identity, native selection routed Reader, and initial/origin closure preserved surviving browsers")
        page.reload()
        state = try await waitForFixture(page, key: "neutrinoFixtureWorker", value: "ready")
        // Wait for the next document's worker ping, not an old DOM state during reload.
        let storageDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (Int(state["neutrinoFixtureCount"] ?? "") ?? 0) <= count, ContinuousClock.now < storageDeadline {
            try await Task.sleep(for: .milliseconds(100)); state = try await fixtureState(page)
        }
        guard state["neutrinoFixtureTheme"] == "dark", (Int(state["neutrinoFixtureCount"] ?? "") ?? 0) > count else {
            throw ValidationError("Extension settings/storage did not survive document reload.")
        }
        // Private Neutrino contexts start without regular-profile extensions.
        let fixturePrivateSession = UUID()
        ChromiumRuntime.shared.beginPrivateSession(fixturePrivateSession)
        defer { ChromiumRuntime.shared.closePrivateSession(fixturePrivateSession) }
        let privatePage = try ChromiumRuntime.shared.makeTab(profileID: manager.profileID, privateSessionID: fixturePrivateSession, dataDirectory: app.dataDirectory)
        defer { privatePage.dispose() }
        privatePage.load(fixtureURL)
        try await waitForLoad(privatePage, host: "127.0.0.1")
        try await Task.sleep(for: .milliseconds(500))
        guard try await evaluate(privatePage, "String(document.documentElement.dataset.neutrinoFixtureContent)") == "undefined" else {
            throw ValidationError("A regular-profile extension ran in an isolated private context.")
        }
        let manifestURL = installedFolder.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] else {
            throw ValidationError("The fixture manifest is invalid.")
        }
        manifest["version"] = "1.0.1"
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
        // For unpacked extensions, this option waits for the real reload's
        // OnExtensionLoaded callback; failQuietly alone returns immediately.
        let reloadError = try await evaluate(manager, "JSON.stringify((await chrome.developerPrivate.reload('\(id)',{failQuietly:true,populateErrorForUnpacked:true})) ?? null)")
        guard reloadError == "null" else { throw ValidationError("The fixture update failed: \(reloadError)") }
        let updated = try await evaluate(manager, "JSON.stringify((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).filter(e => e.id === '\(id)').map(e => ({state:e.state,version:e.version})))")
        guard let updatedData = updated.data(using: .utf8),
              let updatedInfo = try JSONSerialization.jsonObject(with: updatedData) as? [[String: String]],
              updatedInfo.count == 1, updatedInfo[0]["state"] == "ENABLED", updatedInfo[0]["version"] == "1.0.1" else {
            throw ValidationError("The extension manager did not finish loading fixture version 1.0.1: \(updated)")
        }
        page.reload()
        _ = try await waitForFixture(page, key: "neutrinoFixtureVersion", value: "1.0.1")
        _ = try await waitForFixture(page, key: "neutrinoFixtureTheme", value: "dark")
        let beforeDisable = try await fixtureState(page)
        let beforeDisableCount = Int(beforeDisable["neutrinoFixtureCount"] ?? "") ?? 0
        _ = try await evaluate(manager, "String(await chrome.management.setEnabled('\(id)',false))")
        guard try await evaluate(manager, "String((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).find(e => e.id === '\(id)')?.state)") == "DISABLED" else {
            throw ValidationError("The extension manager did not disable the fixture.")
        }
        page.reload(); try await waitForLoad(page, host: "127.0.0.1")
        try await Task.sleep(for: .milliseconds(300))
        guard try await evaluate(page, "String(document.documentElement.dataset.neutrinoFixtureContent)") == "undefined" else {
            throw ValidationError("A disabled extension still injected into a new document.")
        }
        _ = try await evaluate(manager, "String(await chrome.management.setEnabled('\(id)',true))")
        page.reload()
        let restored = try await waitForFixture(page, key: "neutrinoFixtureWorker", value: "ready")
        guard restored["neutrinoFixtureTheme"] == "dark", restored["neutrinoFixtureVersion"] == "1.0.1",
              (Int(restored["neutrinoFixtureCount"] ?? "") ?? 0) > beforeDisableCount else {
            throw ValidationError("Re-enabling the fixture did not restore its worker/content or retained settings/storage.")
        }
        print("Neutrino Chromium acceptance: disabling stopped injection and re-enabling restored worker/content with retained storage")
        // This validates reload/update behavior for a local fixture. Signed Web
        // Store update delivery and whole-process restart are separate checks.
        try await removeFixtureExtension(id, manager: manager)
        let removed = try await evaluate(manager, "String((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).some(e => e.id === '\(id)'))")
        guard removed == "false" else { throw ValidationError("The extension manager did not remove the fixture.") }
        page.reload(); try await waitForLoad(page, host: "127.0.0.1")
        try await Task.sleep(for: .milliseconds(300))
        guard try await evaluate(page, "String(document.documentElement.dataset.neutrinoFixtureContent)") == "undefined" else {
            throw ValidationError("The removed extension still injected into a new document.")
        }
        print("Neutrino Chromium acceptance: native options window, grants, settings, storage, private isolation, local update and removal passed")
        if let menuFailure { throw ValidationError(menuFailure) }
    }
    private static func verifyPristineInactiveTab(options: ChromiumTab, app: AppState, fixtureURL: URL) async throws {
        func extensionTabs() async throws -> [[String: Any]] {
            let json = try await evaluate(options, "JSON.stringify(await chrome.tabs.query({}))")
            guard let data = json.data(using: .utf8),
                  let tabs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ValidationError("The extension did not report its actual profile tabs.")
            }
            return tabs
        }
        let previousIDs = Set(try await extensionTabs().compactMap { $0["id"] as? Int })
        let addedProfile = !app.library.profiles.contains { $0.id == options.profileID }
        if addedProfile { app.library.profiles.append(Profile(id: options.profileID, name: "Inactive tab acceptance")) }
        let browser = BrowserModel(app: app, isPrivate: false)
        browser.session = WindowSession(id: browser.session.id, profileID: options.profileID, tabs: [BrowserTab(engineID: .chromium)])
        let window = NSWindow(contentRect: NSRect(x: 150, y: 110, width: 1000, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserWindow(model: browser).environmentObject(app))
        window.makeKeyAndOrderFront(nil)
        defer {
            browser.closeWindow(); window.close()
            if addedProfile { app.library.profiles.removeAll { $0.id == options.profileID } }
        }
        guard let blank = browser.activeWebTab as? ChromiumTab else {
            throw ValidationError("The pristine pane did not create Chromium.")
        }
        let initialDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !blank.isReadyForEngineSwitch || blank.chromiumSessionPages?.count != 1 || blank.loading {
            guard ContinuousClock.now < initialDeadline else { throw ValidationError("The pristine Chromium pane did not become ready.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        browser.captureChromiumSessions()
        guard blank.url == nil, browser.selectedTab.url == nil, blank.nativeView.window == nil,
              browser.selectedTab.chromiumPages == nil else {
            throw ValidationError("A sole untouched Chromium pane replaced Neutrino's native Start page or saved it as a Chrome tab.")
        }
        let initialZoom = blank.zoom
        let initialMembers = try await nativeBrowsers(blank)
        let initialIDs = Set(initialMembers.compactMap { $0["id"] as? Int })
        let newTabs = try await extensionTabs().filter { !previousIDs.contains($0["id"] as? Int ?? -1) }
        guard initialIDs.count == 1, newTabs.count == 1,
              let initialTabID = newTabs.first?["id"] as? Int,
              let nativeWindowID = newTabs.first?["windowId"] as? Int,
              let chromeWindow = blank.chromeWindow else {
            throw ValidationError("The pristine pane's native browser identity was ambiguous.")
        }
        guard var target = URLComponents(url: fixtureURL, resolvingAgainstBaseURL: false) else { throw ValidationError("The inactive-tab fixture URL is invalid.") }
        target.fragment = "neutrino-pristine-inactive"
        guard let targetURL = target.url else { throw ValidationError("The inactive-tab fixture URL is invalid.") }
        let address = String(decoding: try JSONSerialization.data(withJSONObject: targetURL.absoluteString, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        let created = try await evaluate(options, "String((await chrome.tabs.create({windowId:\(nativeWindowID),active:false,url:\(address)})).id)")
        guard let createdID = Int(created) else { throw ValidationError("The extension did not create an inactive tab.") }
        let siblingDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while blank.chromiumSessionPages?.count != 2 ||
            blank.chromiumSessionPages?.last?.url != targetURL ||
            browser.selectedTab.chromiumPages?.count != 2 ||
            blank.nativeView.window !== window || !blank.hasNativeNavigationChrome {
            guard ContinuousClock.now < siblingDeadline else {
                throw ValidationError("An inactive extension tab stayed hidden or absent from its pristine pane's saved inventory.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        browser.captureChromiumSessions()
        let members = try await nativeBrowsers(blank)
        let selectedIDs = Set(members.filter { $0["active"] as? Bool == true }.compactMap { $0["id"] as? Int })
        guard members.count == 2, selectedIDs == initialIDs,
              blank.chromeWindow === chromeWindow, chromeWindow.parent === window,
              blank.url == nil, browser.selectedTab.url == nil,
              blank.chromiumSessionPages?.first?.url == nil,
              browser.selectedTab.chromiumPages?.last?.url == targetURL,
              try await evaluate(options, "String((await chrome.tabs.get(\(initialTabID))).active)") == "true",
              try await evaluate(options, "String((await chrome.tabs.get(\(createdID))).active)") == "false",
              try await evaluate(options, "String((await chrome.tabs.get(\(createdID))).windowId)") == String(nativeWindowID) else {
            throw ValidationError("Exposing an inactive sibling changed the pristine page's actual selection, identity, or session records.")
        }
        try await verifyChromeGeometry(blank, ownerWindow: window)
        _ = try await evaluate(options, "String((await chrome.tabs.update(\(createdID),{active:true})).id)")
        let selectedDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while blank.url != targetURL || browser.selectedTab.url != targetURL {
            guard ContinuousClock.now < selectedDeadline else { throw ValidationError("Selecting the new sibling did not update the active URL and native Neutrino descriptor.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        let savedZoom = try await evaluate(options, "String(await chrome.tabs.getZoom(\(createdID)))")
        guard let siblingZoom = Double(savedZoom), siblingZoom.isFinite else { throw ValidationError("The fixture did not report its native zoom.") }
        _ = try await evaluate(blank, "(history.pushState(null, '', location.href), 'ready')")
        blank.setZoom(1.5)
        let stateDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !blank.canGoBack || abs(blank.zoom - 1.5) > 0.01 {
            guard ContinuousClock.now < stateDeadline else { throw ValidationError("The HTTP sibling did not expose its changed native history and zoom.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await evaluate(options, "String((await chrome.tabs.update(\(initialTabID),{active:true})).id)")
        let returnedDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !blank.isShowingStartPage || blank.url != nil || browser.selectedTab.url != nil ||
            !browser.address.isEmpty || blank.chromiumSessionPages?.first?.url != nil {
            guard ContinuousClock.now < returnedDeadline else { throw ValidationError("Returning to the untouched blank tab retained the sibling's URL, address, or saved selection.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard Set(try await nativeBrowsers(blank).filter { $0["active"] as? Bool == true }.compactMap { $0["id"] as? Int }) == initialIDs,
              blank.nativeView.window === window, blank.hasNativeNavigationChrome,
              browser.selectedTab.chromiumPages?.last?.url == targetURL else {
            throw ValidationError("Returning to the pristine tab lost the selected browser identity or hid its surviving sibling.")
        }
        let historyData = try await blank.request("Page.getNavigationHistory", parameters: [:])
        guard let history = try JSONSerialization.jsonObject(with: historyData) as? [String: Any],
              let currentIndex = history["currentIndex"] as? Int, let entries = history["entries"] as? [[String: Any]],
              blank.canGoBack == (currentIndex > 0),
              blank.canGoForward == (currentIndex >= 0 && currentIndex + 1 < entries.count),
              !blank.loading, abs(blank.zoom - initialZoom) < 0.01 else {
            throw ValidationError("Returning to the pristine browser retained its sibling's loading, history controls, or zoom.")
        }
        _ = try await evaluate(options, "String(await chrome.tabs.setZoom(\(createdID),\(siblingZoom)))")
        _ = try await evaluate(options, "String(await chrome.tabs.remove(\(createdID)))")
        let removalDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while blank.chromiumSessionPages?.count != 1 || blank.nativeView.window != nil {
            guard ContinuousClock.now < removalDeadline else { throw ValidationError("Closing the inactive sibling did not return the untouched pane to native Start.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        browser.captureChromiumSessions()
        guard Set(try await nativeBrowsers(blank).compactMap { $0["id"] as? Int }) == initialIDs,
              browser.activeWebTab === blank, blank.url == nil, browser.selectedTab.chromiumPages == nil else {
            throw ValidationError("Closing the inactive sibling discarded its original pristine browser or persisted a different Start surface.")
        }
        print("Neutrino Chromium acceptance: pristine pane preserved inactive extension tab identity, mounted its native strip, saved both entries, and returned to Start after removal")
    }
    private static func fixtureState(_ tab: ChromiumTab) async throws -> [String: String] {
        if tab.loading { return [:] }
        let text = try await evaluate(tab, "JSON.stringify(document.documentElement ? document.documentElement.dataset : {})")
        guard let data = text.data(using: .utf8), let result = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw ValidationError("The fixture returned invalid state.")
        }
        if let error = result["neutrinoFixtureError"] { throw ValidationError("Extension API fixture: \(error)") }
        return result
    }
    private static func waitForAuxiliary(profileID: UUID, query: String) async throws -> ChromiumTab {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if let tab = ChromiumRuntime.shared.auxiliaryTabs.first(where: { $0.profileID == profileID && $0.url?.query == query }) {
                _ = try await waitForFixture(tab, key: "neutrinoFixtureOptionsState", value: "ready")
                if tab.chromeWindow?.isVisible == true { return tab }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError("The extension-created auxiliary browser did not load: \(query)")
    }
    private static func waitForFixture(_ tab: ChromiumTab, key: String, value: String) async throws -> [String: String] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var state: [String: String] = [:]
        while ContinuousClock.now < deadline {
            if let error = tab.errorMessage { throw ValidationError(error) }
            state = try await fixtureState(tab)
            if state[key] == value { return state }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError("Extension API fixture did not reach \(key)=\(value) (state=\(state), loading=\(tab.loading), url=\(tab.url?.absoluteString ?? "nil")).")
    }
    private static func click(_ tab: ChromiumTab, selector: String) async throws {
        try await focusPage(tab)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: selector, options: [.fragmentsAllowed]), as: UTF8.self)
        let point = try await evaluate(tab, "JSON.stringify((() => { const e=document.querySelector(\(encoded)); if (!e) return null; const r=e.getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2}; })())")
        guard let data = point.data(using: .utf8), let position = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Double],
              let x = position["x"], let y = position["y"] else { throw ValidationError("The extension fixture control is unavailable: \(selector)") }
        _ = try await tab.request("Input.dispatchMouseEvent", parameters: ["type":"mousePressed", "x":x, "y":y, "button":"left", "clickCount":1])
        _ = try await tab.request("Input.dispatchMouseEvent", parameters: ["type":"mouseReleased", "x":x, "y":y, "button":"left", "clickCount":1])
    }
    private static func focusPage(_ tab: ChromiumTab) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            NSApp.activate(ignoringOtherApps: true)
            tab.nativeView.window?.makeKeyAndOrderFront(nil)
            tab.chromeWindow?.makeKeyAndOrderFront(nil)
            tab.focus()
            if tab.chromeWindow?.isKeyWindow == true {
                if tab.isAuxiliary { return }
                let data = try await tab.request("Neutrino.chromeHostState", parameters: [:])
                if (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["windowActive"] as? Bool == true { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError("The native Chromium acceptance window did not become key and active before input (appActive=\(NSApp.isActive), child=\(tab.chromeWindow?.windowNumber ?? -1), childVisible=\(tab.chromeWindow?.isVisible == true), childKey=\(tab.chromeWindow?.isKeyWindow == true), actualKey=\(NSApp.keyWindow?.windowNumber ?? -1), parent=\(tab.nativeView.window?.windowNumber ?? -1), modal=\(NSApp.modalWindow?.windowNumber ?? -1)).")
    }
    private static func waitForLoad(_ tab: ChromiumTab, host: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while tab.url?.host != host || tab.loading {
            if let error = tab.errorMessage { throw ValidationError(error) }
            guard ContinuousClock.now < deadline else { throw ValidationError("The extension acceptance page did not load.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private static func verifyWebStore(_ tab: ChromiumTab, app: AppState) async throws {
        // Fixed public MV3 extension, installed only into the fresh acceptance
        // profile above. Never run this probe in the user's browsing profile.
        let extensionID = "ddkjiahejlhfcafbddmgiahcphecmpfh"
        tab.load(URL(string: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(extensionID)?hl=en")!)
        try await waitForLoad(tab, host: "chromewebstore.google.com")
        let storeEnvironment = (try? await evaluate(tab, """
        JSON.stringify({origin:location.origin,userAgent:navigator.userAgent,
            brands:navigator.userAgentData?.brands,serverChrome:window.IJ_values?.[24] === true,
            featureFlags:String(window._F_toggles_default_ChromeWebStoreConsumerFeUi?.[0]).slice(0,64),
            chrome:typeof window.chrome,management:typeof window.chrome?.management,
            webstorePrivate:typeof window.chrome?.webstorePrivate,
            beginInstall:typeof window.chrome?.webstorePrivate?.beginInstallWithManifest3,
            completeInstall:typeof window.chrome?.webstorePrivate?.completeInstall,
            extensionStatus:typeof window.chrome?.webstorePrivate?.getExtensionStatus,
            incognito:window.chrome?.extension?.inIncognitoContext})
        """)) ?? "unavailable"
        print("Neutrino Chromium Web Store environment: \(storeEnvironment)")
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        var clickedInstall = false
        while ContinuousClock.now < deadline {
            if let error = tab.errorMessage { throw ValidationError(error) }
            // Focusing and scrolling can move the page. Compute the real hit
            // target afterward, including the site's optional Chrome promotion.
            try await focusPage(tab)
            let value = try await evaluate(tab, """
            (() => {
                const point = (element,kind) => {
                    if (element.disabled || element.getAttribute('aria-disabled') === 'true') return null;
                    const old = element.getBoundingClientRect();
                    if (!old.width || !old.height) return null;
                    element.scrollIntoView({block:'center',inline:'center',behavior:'instant'});
                    const r = element.getBoundingClientRect(), x=r.x+r.width/2, y=r.y+r.height/2;
                    if (x<0 || y<0 || x>=innerWidth || y>=innerHeight) return null;
                    let hit=document.elementFromPoint(x,y);
                    while (hit?.shadowRoot) {
                        const child=hit.shadowRoot.elementFromPoint(x,y);
                        if (!child || child===hit) break;
                        hit=child;
                    }
                    return hit && (element===hit || element.contains(hit)) ?
                        {kind,x,y,controller:element.closest('[jscontroller]')?.getAttribute('jscontroller')} : null;
                };
                const visit = (root,label,kind) => {
                    for (const element of root.querySelectorAll('*')) {
                        if (element.shadowRoot) { const found = visit(element.shadowRoot,label,kind); if (found) return found; }
                        if ((element.tagName === 'BUTTON' || element.getAttribute('role') === 'button') &&
                            element.textContent.trim() === label) {
                            const result=point(element,kind); if (result) return result;
                        }
                    }
                    return null;
                };
                const promo=document.querySelector('[role="dialog"][aria-labelledby="promo-header"]');
                if (promo?.querySelector('#promo-header')?.textContent.trim()==='Switch to Chrome?') {
                    const dismiss=visit(promo,'No thanks','dismissPromotion');
                    if (dismiss) return JSON.stringify(dismiss);
                }
                return JSON.stringify(visit(document,'Add to Chrome','install'));
            })()
            """)
            if let bytes = value.data(using: .utf8),
               let point = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) as? [String: Any],
               let kind = point["kind"] as? String, let x = point["x"] as? Double, let y = point["y"] as? Double {
                print("Neutrino Chromium Web Store pointer target: \(value)")
                _ = try await tab.request("Input.dispatchMouseEvent", parameters: ["type":"mousePressed", "x":x, "y":y, "button":"left", "clickCount":1])
                _ = try await tab.request("Input.dispatchMouseEvent", parameters: ["type":"mouseReleased", "x":x, "y":y, "button":"left", "clickCount":1])
                if kind == "install" { clickedInstall = true; break }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard clickedInstall else {
            if let output = ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_OUTPUT"], let chrome = tab.chromeWindow {
                await AppSmokeTest.captureWindow(chrome, to: URL(fileURLWithPath: output).appendingPathComponent("Neutrino-webstore-install-target-timeout.png"))
            }
            throw ValidationError("The live Chrome Web Store did not offer a visible, enabled Add to Chrome button for the MV3 acceptance extension.")
        }
        // Inspect our own native accessibility tree and press only the enabled
        // Add extension button on this fixed fixture's real permission dialog.
        print("Neutrino Chromium acceptance: waiting for the native Web Store permission dialog")
        var approved = false
        var verifier: ChromiumTab?
        defer { verifier?.dispose() }
        var lastPromptState = ""
        let installDeadline = ContinuousClock.now.advanced(by: .seconds(45))
        while ContinuousClock.now < installDeadline {
            if !approved {
                let response = try await tab.request("Neutrino.acceptFixtureExtension", parameters: [:])
                approved = (try JSONSerialization.jsonObject(with: response) as? [String: Any])?["pressed"] as? Bool == true
                let promptState = String(decoding: response, as: UTF8.self)
                if promptState != lastPromptState {
                    print("Neutrino Chromium native extension prompt: \(promptState)")
                    lastPromptState = promptState
                }
                if approved { print("Neutrino Chromium acceptance: pressed the fixture's native Add extension button") }
            }
            if approved {
                // Extensions can select an onboarding tab after installation.
                // Query the same profile's real manager in a separate hidden
                // native browser so the Store's initiating WebContents remains
                // intact throughout its install, regardless of selected tab.
                if verifier == nil {
                    verifier = try ChromiumRuntime.shared.makeTab(profileID: tab.profileID, privateSessionID: nil, dataDirectory: app.dataDirectory)
                    verifier?.showExtensions()
                }
                if let verifier, verifier.url?.host == "extensions", !verifier.loading {
                    let state = try await evaluate(verifier, "String((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).find(e => e.id === '\(extensionID)')?.state)")
                    if state == "ENABLED" {
                        tab.showExtensions(); try await waitForManager(tab)
                        print("Neutrino Chromium acceptance: live Chrome Web Store install passed for \(extensionID)")
                        return
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        if let output = ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_OUTPUT"], let chrome = tab.chromeWindow {
            await AppSmokeTest.captureWindow(chrome, to: URL(fileURLWithPath: output).appendingPathComponent("Neutrino-webstore-permission-timeout.png"))
        }
        throw ValidationError("The native Chrome Web Store installation was not approved and completed before its deadline.")
    }
}
