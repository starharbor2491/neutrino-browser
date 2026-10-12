// SPDX-License-Identifier: MPL-2.0
import AppKit
import NeutrinoCore
@preconcurrency import WebKit

/// Runs against the bundled privileged UI in an actual macOS application window.
/// The local web harness is deliberately not a substitute for these checks.
@MainActor enum RustShellAcceptance {
    static func webView(in root: NSView?) -> WKWebView? {
        guard let root else { return nil }
        if let web = root as? WKWebView, web.url?.scheme == "neutrino-ui" { return web }
        return root.subviews.lazy.compactMap { webView(in: $0) }.first
    }
    static func waitForShell(in window: NSWindow) async throws -> WKWebView {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if let web = webView(in: window.contentView), (try? await web.evaluateJavaScript("!!document.querySelector('.app-shell')")) as? Bool == true { return web }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError("The bundled Rust interface did not become ready.")
    }
    static func action(_ request: [String: Any], web: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: request)
        let json = String(decoding: data, as: UTF8.self)
        _ = try await web.callAsyncJavaScript("await window.neutrino.command(request);", arguments: ["request": try JSONSerialization.jsonObject(with: Data(json.utf8))], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(80))
    }
    static func verify(window: NSWindow, app: AppState, model: BrowserModel, output: URL) async throws {
        let web = try await waitForShell(in: window)
        let initialFrame = window.frame
        defer { window.setFrame(initialFrame, display: true) }
        for width in [1240,760] {
            window.setContentSize(NSSize(width: CGFloat(width), height: width == 760 ? 520 : 820))
            try await Task.sleep(for: .milliseconds(160))
            let fits = try await web.evaluateJavaScript("document.documentElement.scrollWidth <= innerWidth && !!document.querySelector('.start-search') && document.querySelector('.start-search').getBoundingClientRect().right <= innerWidth") as? Bool
            guard fits == true else { throw ValidationError("The Rust start surface overflows the supported window size.") }
            await AppSmokeTest.captureWindow(window, to: output.appendingPathComponent("Neutrino-shell-\(width).png"))
        }
        window.setContentSize(NSSize(width:1240,height:820))
        // Exercise native tab closing in the real app event loop, including the
        // address palette. SwiftPM's test runner does not own that event loop.
        let originalTab = model.session.selectedTabID, tabCount = model.session.tabs.count
        try await action(["op":"newTab"],web:web)
        guard (try await web.evaluateJavaScript("!!document.querySelector('#start-input') && !document.querySelector('.command-palette')")) as? Bool == true else { throw ValidationError("New tab did not open its inline search surface.") }
        try await action(["op":"palette"],web:web)
        guard model.session.tabs.count == tabCount + 1,
              (try await web.evaluateJavaScript("!!document.querySelector('.command-palette')")) as? Bool == true else { throw ValidationError("New tab did not create a browser tab with its address palette.") }
        window.makeKey(); window.makeFirstResponder(web)
        for type in [NSEvent.EventType.keyDown,.keyUp] {
            guard let event = NSEvent.keyEvent(with:type,location:.zero,modifierFlags:.command,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"w",charactersIgnoringModifiers:"w",isARepeat:false,keyCode:13) else { throw ValidationError("Could not create the tab-close keyboard event.") }
            NSApp.postEvent(event,atStart:false)
        }
        let closeDeadline = ContinuousClock.now.advanced(by:.seconds(5))
        while ContinuousClock.now < closeDeadline {
            if model.session.tabs.count == tabCount,
               (try await web.evaluateJavaScript("!document.querySelector('.command-palette')")) as? Bool == true { break }
            try await Task.sleep(for:.milliseconds(30))
        }
        guard model.session.tabs.count == tabCount, model.session.selectedTabID == originalTab,
              window.isVisible, !model.isClosed,
              (try await web.evaluateJavaScript("!document.querySelector('.command-palette')")) as? Bool == true else { throw ValidationError("Command-W did not close the address-palette tab while retaining its browser window.") }
        print("Neutrino Rust shell acceptance: Command-W closed the palette tab and retained its window")
        // Drive actual DOM buttons through WebKit and the Rust/native command bridge.
        _ = try await web.evaluateJavaScript("document.querySelector('#start-input').focus()")
        try await Task.sleep(for:.milliseconds(100))
        guard (try await web.evaluateJavaScript("document.activeElement.id === 'start-input'")) as? Bool == true else { throw ValidationError("Search did not receive keyboard focus.") }
        try await action(["op":"escape"], web:web)
        try await action(["op":"screen","value":"editor"],web:web)
        let original = model.configuration
        try await action(["op":"dock","component":"tabs","region":"trailing"],web:web)
        guard model.configuration == original else { throw ValidationError("An unsaved editor draft changed live configuration.") }
        await AppSmokeTest.captureWindow(window,to:output.appendingPathComponent("Neutrino-customize.png"))
        try await action(["op":"editor-undo"],web:web)
        try await action(["op":"editor-save"],web:web)
        guard model.configuration.layout.tabs == original.layout.tabs else { throw ValidationError("Editor undo was not applied before Save.") }
        for screen in ["settings","modules","extensions","library"] {
            try await action(["op":"screen","value":screen,"section":"general"],web:web)
            guard (try await web.evaluateJavaScript(screen == "library" ? "!!document.querySelector('.library-content')" : "!!document.querySelector('.utility-screen')")) as? Bool == true else { throw ValidationError("The \(screen) interface did not render.") }
            try await recordScrollGeometry(web, label:screen)
            await AppSmokeTest.captureWindow(window,to:output.appendingPathComponent("Neutrino-\(screen).png"))
            try await action(["op":"escape"],web:web)
        }
        // Moving a tab must retain both its live document and browsing context.
        model.newTab(url:URL(string:"https://example.com"),engine:.webkit)
        let moving=model.selectedTab.id, page=model.activeWebTab, profile=model.session.profileID
        try await Task.sleep(for:.milliseconds(100))
        try await action(["op":"move-tab","id":moving.uuidString,"group":"pinned"],web:web)
        guard model.selectedTab.pinned, model.activeWebTab === page, model.session.profileID == profile else { throw ValidationError("A tab move lost its live document or Profile.") }
        try await action(["op":"undo-tabs"],web:web)
        guard !model.selectedTab.pinned, model.activeWebTab === page else { throw ValidationError("Tab move Undo did not preserve the document.") }
        model.closeTab(moving)
        var dark = model.configuration; dark.theme.colorMode = .dark
        app.applyConfiguration(dark,to:model.session.spaceID)
        try await Task.sleep(for:.milliseconds(150))
        await AppSmokeTest.captureWindow(window,to:output.appendingPathComponent("Neutrino-shell-dark.png"))
        app.applyConfiguration(original,to:model.session.spaceID)
    }
    static func verifyPageGeometry(window:NSWindow, model:BrowserModel, output:URL) async throws {
        let web=try await waitForShell(in:window)
        try await action(["op":"screen","value":"browse"],web:web)
        try await Task.sleep(for:.milliseconds(200))
        let geometry = try await web.evaluateJavaScript("(()=>{const p=document.querySelector('.native-page');if(!p)return null;const r=p.getBoundingClientRect();return {width:r.width,height:r.height,x:r.x,y:r.y};})()") as? [String:Double]
        guard let geometry, geometry["width",default:0]>=300, geometry["height",default:0]>=250,
              model.activeWebTab.nativeView.window === window,
              abs(model.activeWebTab.nativeView.bounds.width-geometry["width",default:0]) < 3 else { throw ValidationError("The native page does not match the Rust-rendered page region.") }
        let page = model.activeWebTab
        let configuration = model.configuration
        try await installInputProbe(page)
        page.focus()
        sendKey(to: (page as? ChromiumTab)?.chromeWindow ?? window)
        try await Task.sleep(for:.milliseconds(100))
        let before = try await inputProbeCount(page)
        guard before > 0 else { throw ValidationError("The editor input test could not deliver its browsing control key.") }
        try await action(["op":"screen","value":"editor"],web:web)
        try await action(["op":"dock","component":"tabs","region":"trailing"],web:web)
        let preview = try await web.evaluateJavaScript("document.querySelector('.editing-preview .native-page').getBoundingClientRect().width") as? Double
        guard let preview, preview > 100,
              model.activeWebTab === page,
              let container = page.nativeView.superview as? EngineViewContainer,
              container.window === window, !container.isHidden, container.isPreviewing,
              abs(page.nativeView.bounds.width-preview) < 3,
              model.configuration == configuration else { throw ValidationError("The editor did not preserve its live page and isolated layout draft.") }
        page.focus() // Programmatic page activation must also remain suspended.
        sendKey(to: window)
        let point = page.nativeView.convert(NSPoint(x:20,y:20),to:nil)
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            if let event = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1) { NSApp.postEvent(event, atStart:false) }
        }
        try await Task.sleep(for:.milliseconds(100))
        guard try await inputProbeCount(page) == before else { throw ValidationError("Editing delivered keyboard or mouse input to the live page.") }
        if let chrome = (page as? ChromiumTab)?.chromeWindow {
            guard chrome.ignoresMouseEvents, !chrome.isKeyWindow else { throw ValidationError("The Chromium child still accepts input during editing.") }
        }
        _ = try await evaluatePage(page,"document.getElementById('neutrino-input-probe').style.opacity='0'; 'ok'")
        await AppSmokeTest.captureWindow(window,to:output.appendingPathComponent("Neutrino-editor-live-\(page.engineID.rawValue).png"))
        try await recordScrollGeometry(web, label:"editor-\(page.engineID.rawValue)")
        try await action(["op":"editor-preview-size"],web:web)
        let expanded = try await web.evaluateJavaScript("document.querySelector('.editing-preview .native-page').getBoundingClientRect().width") as? Double
        guard let expanded, expanded > preview + 80, model.activeWebTab === page,
              abs(page.nativeView.bounds.width-expanded) < 3 else { throw ValidationError("Expanding the live preview lost its document or geometry.") }
        await AppSmokeTest.captureWindow(window,to:output.appendingPathComponent("Neutrino-editor-expanded-\(page.engineID.rawValue).png"))
        try await action(["op":"editor-preview-size"],web:web)
        try await action(["op":"editor-cancel"],web:web)
        guard model.activeWebTab === page,
              (page.nativeView.superview as? EngineViewContainer)?.isPreviewing == false else { throw ValidationError("Cancel did not restore browsing on the original page.") }
        page.focus()
        sendKey(to: (page as? ChromiumTab)?.chromeWindow ?? window)
        try await Task.sleep(for:.milliseconds(100))
        guard try await inputProbeCount(page) > before else { throw ValidationError("Closing the editor did not restore page keyboard input.") }
        _ = try await evaluatePage(page,"document.getElementById('neutrino-input-probe')?.remove(); 'ok'")
    }
    private static func recordScrollGeometry(_ web:WKWebView,label:String) async throws {
        let value = try await web.evaluateJavaScript("JSON.stringify([...document.querySelectorAll('*')].filter(e=>['auto','scroll'].includes(getComputedStyle(e).overflowY)&&e.scrollHeight>e.clientHeight).map(e=>({element:e.tagName+'.'+e.className,height:e.clientHeight,content:e.scrollHeight,top:e.scrollTop,rect:e.getBoundingClientRect().toJSON()})))")
        print("Neutrino Rust scroll geometry \(label): \(value)")
    }
    private static func sendKey(to window:NSWindow) {
        for type in [NSEvent.EventType.keyDown,.keyUp] {
            if let event=NSEvent.keyEvent(with:type,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"x",charactersIgnoringModifiers:"x",isARepeat:false,keyCode:7) { NSApp.postEvent(event, atStart:false) }
        }
    }
    private static func installInputProbe(_ page:BrowserEngineTab) async throws {
        _ = try await evaluatePage(page,"(()=>{window.neutrinoProbeCount=0;const input=document.createElement('input');input.id='neutrino-input-probe';input.style='position:fixed;left:8px;top:8px;z-index:2147483647;width:100px';document.body.append(input);document.addEventListener('keydown',()=>window.neutrinoProbeCount++);document.addEventListener('mousedown',()=>window.neutrinoProbeCount++);input.focus();return 'ok';})()")
    }
    private static func inputProbeCount(_ page:BrowserEngineTab) async throws -> Int {
        Int(try await evaluatePage(page,"String(window.neutrinoProbeCount)")) ?? -1
    }
    private static func evaluatePage(_ page:BrowserEngineTab,_ expression:String) async throws -> String {
        if let web=page as? WebTab { return (try await web.webView.evaluateJavaScript(expression)) as? String ?? "" }
        if let chrome=page as? ChromiumTab {
            let data=try await chrome.request("Runtime.evaluate",parameters:["expression":expression,"returnByValue":true])
            let object=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            return (object?["result"] as? [String:Any])?["value"] as? String ?? ""
        }
        throw ValidationError("The editor input test requires a website engine.")
    }
}
