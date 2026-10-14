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
            let fits = try await web.evaluateJavaScript("document.documentElement.scrollWidth <= innerWidth && !!document.querySelector('.page-workspace') && document.querySelector('.page-workspace').getBoundingClientRect().right <= innerWidth") as? Bool
            guard fits == true else { throw ValidationError("The browsing workspace overflows the supported window size.") }
            await AppSmokeTest.captureWindow(window, to: output.appendingPathComponent("Neutrino-shell-\(width).png"))
        }
        window.setContentSize(NSSize(width:1240,height:820))
        // Exercise native tab closing in the real app event loop, including the
        // address palette. SwiftPM's test runner does not own that event loop.
        let originalTab = model.session.selectedTabID, tabCount = model.session.tabs.count
        try await action(["op":"newTab"],web:web)
        guard model.session.tabs.count == tabCount, model.session.selectedTabID == originalTab,
              (try await web.evaluateJavaScript("!!document.querySelector('.command-palette') && document.activeElement.id==='command-input' && !document.querySelector('#start-input')")) as? Bool == true else { throw ValidationError("New Tab must focus commands without creating a blank tab or replacing the current page.") }
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
              (try await web.evaluateJavaScript("!document.querySelector('.command-palette')")) as? Bool == true else { throw ValidationError("Command-W did not cancel commands while retaining the original page and browser window.") }
        print("Neutrino Rust shell acceptance: Command-W cancelled commands and retained the page")
        // Drive actual DOM buttons through WebKit and the Rust/native command bridge.
        try await action(["op":"newTab"],web:web)
        try await Task.sleep(for:.milliseconds(100))
        guard (try await web.evaluateJavaScript("document.activeElement.id === 'command-input'")) as? Bool == true else { throw ValidationError("Commands did not receive keyboard focus.") }
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
    static func verifyResearchWorkspace(window: NSWindow, app: AppState, model: BrowserModel, output: URL) async throws {
        let web = try await waitForShell(in: window)
        let page = model.activeWebTab, originalID = model.session.selectedTabID
        guard let researchSpace=model.session.spaceID else {throw ValidationError("The research check requires a Space.")}
        let originalConfiguration = model.configuration
        guard let source = page.url else { throw ValidationError("The research check needs a loaded website.") }
        let count = app.library.notes.count
        print("Neutrino research stage: \(page.engineID.rawValue) initial quote")
        try await action(["op":"screen","value":"browse"],web:web)
        _ = try await evaluatePage(page, "(()=>{window.neutrinoResearchDraft='retained';const range=document.createRange();range.selectNodeContents(document.querySelector('main blockquote'));const selected=getSelection();selected.removeAllRanges();selected.addRange(range);return 'selected';})()")
        let selectedText=try await page.selectedText()
        guard selectedText=="A useful interface preserves the work already in progress." else {throw ValidationError("The fixture quote was not selected in \(page.engineID.rawValue): \(selectedText)")}
        try await action(["op":"section","value":"notes"], web: web)
        _ = try await web.evaluateJavaScript("document.querySelector('[data-op=native][data-action=quoteSelection]').click()")
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while app.library.notes.count == count && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(40)) }
        try await Task.sleep(for: .milliseconds(160))
        let panelVisible=(try await web.evaluateJavaScript("!!document.querySelector('.workspace-panel textarea')")) as? Bool == true
        guard let note = app.library.notes.last, app.library.notes.count == count + 1,
              note.quotedText=="A useful interface preserves the work already in progress.", note.sourceURL == source,
              note.spaceID == model.session.spaceID,
              note.profileID == model.session.profileID,
              note.sourceTabID == originalID, panelVisible,
              model.activeWebTab === page, !page.nativeView.isHidden else {
            let note=app.library.notes.last
            throw ValidationError("Quote failed in \(page.engineID.rawValue): count=\(app.library.notes.count-count), quote=\(note?.quotedText ?? "nil"), source=\(note?.sourceURL?.absoluteString ?? "nil"), expected=\(source.absoluteString), Space=\(note?.spaceID==model.session.spaceID), panel=\(panelVisible), retained=\(model.activeWebTab===page), hidden=\(page.nativeView.isHidden), notice=\(app.notice ?? "none")")
        }
        let annotation="Keep the source beside the draft. Compare the guidance, then return to the original document without losing the work in progress."
        let encodedAnnotation=String(decoding:try JSONSerialization.data(withJSONObject:annotation,options:[.fragmentsAllowed]),as:UTF8.self)
        _ = try await web.evaluateJavaScript("(()=>{const e=document.querySelector('.workspace-panel textarea[data-note=\"\(note.id.uuidString)\"]');e.value=\(encodedAnnotation);e.dispatchEvent(new Event('input',{bubbles:true}));return true;})()")
        let editDeadline=ContinuousClock.now.advanced(by:.seconds(5))
        while app.library.notes.first(where:{$0.id==note.id})?.text != annotation && ContinuousClock.now < editDeadline {try await Task.sleep(for:.milliseconds(40))}
        guard app.library.notes.first(where:{$0.id==note.id})?.text==annotation else {throw ValidationError("Editing the source-linked note did not reach the native store.")}
        guard await app.flush() else { throw ValidationError("The quote and annotation could not be saved.") }
        let database = try LibraryDatabase(url: app.dataDirectory.appendingPathComponent("library.sqlite"))
        let restored = try await database.load()
        guard restored.notes.contains(where: { $0.id == note.id && $0.text==annotation && $0.quotedText == note.quotedText && $0.sourceURL == source && $0.spaceID == model.session.spaceID }) else {
            throw ValidationError("The quote and edited annotation did not survive a database reload.")
        }
        try await verifyNoteRetrieval(app: app, model: model, web: web, note: note)
        print("Neutrino research stage: \(page.engineID.rawValue) comparison quote")
        let comparisonURL = source.appendingPathComponent("comparison")
        model.newTab(url: comparisonURL, engine: page.engineID)
        let comparison = model.session.selectedTabID
        defer { model.endSplit(); model.closeTab(comparison); model.selectTab(originalID); app.applyConfiguration(originalConfiguration, to: model.session.spaceID) }
        let secondDeadline = ContinuousClock.now.advanced(by: .seconds(12))
        while (model.activeWebTab.loading || model.activeWebTab.title != "Calm workspaces") && ContinuousClock.now < secondDeadline { try await Task.sleep(for: .milliseconds(40)) }
        guard !model.activeWebTab.loading, model.activeWebTab.title == "Calm workspaces" else {throw ValidationError("The research comparison page did not finish loading before quotation.")}
        _ = try await evaluatePage(model.activeWebTab,"(()=>{const range=document.createRange();range.selectNodeContents(document.querySelector('main blockquote'));const selected=getSelection();selected.removeAllRanges();selected.addRange(range);return 'selected';})()")
        try await action(["op":"native","action":"quoteSelection"], web:web)
        let quoteDeadline = ContinuousClock.now.advanced(by:.seconds(8))
        while app.library.notes.count == count+1 && ContinuousClock.now < quoteDeadline { try await Task.sleep(for:.milliseconds(40)) }
        guard let other=app.library.notes.last,app.library.notes.count==count+2,other.sourceURL==comparisonURL,
              other.quotedText=="A calm workspace makes the next step easy to find.",other.spaceID==note.spaceID else {throw ValidationError("The second source quote lost its project or source context.")}
        try await action(["op":"split-with","id":originalID.uuidString], web: web)
        print("Neutrino research stage: \(page.engineID.rawValue) retained split and setups")
        guard model.session.split?.contains(originalID) == true,
              model.webTab(originalID) === page,
              try await evaluatePage(page,"window.neutrinoResearchDraft") == "retained" else {
            throw ValidationError("Splitting the research workspace lost the live document.")
        }
        model.selectTab(originalID)
        try await action(["op":"screen","value":"editor"], web: web)
        try await action(["op":"editor-preset","value":"chrome"], web: web)
        try await action(["op":"editor-save"], web: web)
        guard model.configuration.layout.tabs == .top,
              model.webTab(originalID) === page,
              try await evaluatePage(page,"window.neutrinoResearchDraft") == "retained" else {
            throw ValidationError("A saved browser preset discarded the live research page.")
        }
        // Save a real named setup with the live pair, change the draft, reload it,
        // then prove both the setup and its Space presentation survive storage.
        try await action(["op":"split-with","id":comparison.uuidString],web:web)
        let savedPair=try unwrapSplit(model)
        try await action(["op":"screen","value":"editor"],web:web)
        let setupName="Acceptance research " + page.engineID.rawValue
        try await action(["op":"name","value":setupName],web:web)
        try await action(["op":"editor-save-named"],web:web)
        guard let setup=app.library.preferences.savedConfigurations.last(where:{$0.name==setupName}) else {throw ValidationError("The named research setup was not saved.")}
        try await action(["op":"editor-preset","value":"arc"],web:web)
        try await action(["op":"editor-load-named","id":setup.id.uuidString],web:web)
        try await action(["op":"editor-save"],web:web)
        guard model.configuration.layout.tabs == .top,model.configuration.layout.split == .sideBySide,
              model.session.split==savedPair else {throw ValidationError("The named research setup did not restore its saved layout and live split.")}
        // Deliberately put another tab with the same URL ahead of the captured
        // document. Recovery must select the original identity, not first URL.
        model.newTab(url:source,engine:page.engineID)
        let duplicate=model.session.selectedTabID
        defer {model.switchSpace(researchSpace);model.closeTab(duplicate)}
        model.pinTab(duplicate)
        model.selectTab(originalID)
        guard let away = app.createSpace(name:"Acceptance scratch " + page.engineID.rawValue,profileID:model.session.profileID) else { throw ValidationError("The research Space round-trip could not start.") }
        model.switchSpace(away)
        try await Task.sleep(for:.milliseconds(160))
        guard (try await web.evaluateJavaScript("!document.querySelector('.note-quote')")) as? Bool == true else { throw ValidationError("Research quotes leaked into another Space.") }
        try await action(["op":"open-panel","value":"notes"],web:web)
        try await action(["op":"native","action":"notesScope","value":"all"],web:web)
        try await action(["op":"native","action":"openNoteSource","id":note.id.uuidString],web:web)
        guard model.session.spaceID==researchSpace,model.session.selectedTabID==originalID,model.activeWebTab===page,
              model.session.split?.contains(originalID)==true,
              try await evaluatePage(page,"window.neutrinoResearchDraft")=="retained" else {throw ValidationError("Opening the source after a Space round-trip did not recover the retained page.")}
        guard await app.flush() else {throw ValidationError("The complete research workspace could not be saved.")}
        let complete = try await database.load()
        guard complete.preferences.savedConfigurations.contains(where:{$0.id==setup.id && $0.configuration==setup.configuration}),
              complete.sessions.contains(where:{$0.id==model.session.id && $0.spaceID==researchSpace && $0.split==model.session.split}) else {throw ValidationError("The named layout and split did not survive a database reload.")}
        guard complete.notes.contains(where:{$0.spaceID==researchSpace && $0.sourceURL==source && $0.id==note.id && $0.text==annotation}),
              complete.notes.contains(where:{$0.id==other.id && $0.sourceURL==comparisonURL && $0.quotedText==other.quotedText}) else {throw ValidationError("The two-source workspace did not survive a storage reload.")}
        model.moveTab(originalID,toSpace:away)
        try await action(["op":"native","action":"notesScope","value":"space"],web:web)
        try await action(["op":"native","action":"notesQuery","value":"A useful interface"],web:web)
        try await action(["op":"native","action":"selectNote","id":note.id.uuidString],web:web)
        try await action(["op":"native","action":"openNoteSource","id":note.id.uuidString],web:web)
        guard model.session.spaceID==away,model.session.selectedTabID==originalID,model.activeWebTab===page,
              try await evaluatePage(page,"window.neutrinoResearchDraft")=="retained",
              (try await web.evaluateJavaScript("document.querySelector('.workspace-panel textarea')?.dataset.note")) as? String == note.id.uuidString,
              (try await web.evaluateJavaScript("document.querySelector('.notes-scope .selected')?.textContent")) as? String == "All notes",
              (try await web.evaluateJavaScript("document.querySelector('.notes-search')?.value")) as? String == "" else {throw ValidationError("Moved-source recovery lost the original live page or hid its selected project note.")}
        model.moveTab(originalID,toSpace:researchSpace)
        model.switchSpace(researchSpace);model.selectTab(originalID)
        try await action(["op":"native","action":"notesScope","value":"space"],web:web)
        try await action(["op":"section","value":"notes"], web: web)
        do {
            let captureFrame=window.frame,captureConfiguration=model.configuration
            defer {window.setFrame(captureFrame,display:true);app.applyConfiguration(captureConfiguration,to:model.session.spaceID)}
            var presentation=captureConfiguration;presentation.layout.tabs = .leading;presentation.theme.colorMode = .dark
            app.applyConfiguration(presentation,to:model.session.spaceID)
            window.setContentSize(NSSize(width:1240,height:760))
            try await Task.sleep(for: .milliseconds(200))
            await AppSmokeTest.captureWindow(window, to: output.appendingPathComponent("Neutrino-research-\(page.engineID.rawValue).png"))
        }
        try await verifyLargeNoteProjection(app:app,model:model,web:web)
        let receipt = output.deletingLastPathComponent().appendingPathComponent("research-acceptance.json")
        var evidence = (try? JSONSerialization.jsonObject(with: Data(contentsOf: receipt))) as? [String: Any] ?? [:]
        evidence[page.engineID.rawValue] = ["quoteWithSource":true,"editedNoteBody":true,"twoDistinctSources":true,"spaceScope":true,"openSource":true,"databaseReload":true,"retainedPageThroughSplit":true,"savedPresetPreservesPage":true,"namedSetupReload":true,"splitRestoration":true,"sourceTabIdentity":true,"crossSpaceSourceRecovery":true,"movedSourceRecovery":true,"movedSourceNoteVisibility":true,"quoteSearch":true,"noteContentSearch":true,"distinctQuoteExcerpts":true,"largeNoteProjection":true]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted,.sortedKeys]).write(to: receipt, options: .atomic)
        print("Neutrino research acceptance: \(page.engineID.rawValue) quote, source, durable note, retained split, and saved preset passed")
    }
    private static func verifyNoteRetrieval(app: AppState, model: BrowserModel, web: WKWebView, note: Note) async throws {
        let original = app.library.notes
        defer { app.library.notes = original }
        var second = note; second.id = UUID()
        second.quotedText = String(repeating: "Another quotation. ", count: 100) + "Unique quotation phrase"
        second.text = String(repeating: "Research context. ", count: 100) + "Unique body phrase"
        app.library.notes.append(second)
        try await action(["op":"native","action":"notesQuery","value":""], web:web)
        let excerpt = try await web.evaluateJavaScript("document.querySelector('[data-action=selectNote][data-id=\"\(second.id.uuidString)\"] .note-excerpt')?.textContent") as? String
        guard excerpt?.contains("Another quotation") == true, excerpt != note.quotedText else { throw ValidationError("Same-source quotations have no distinctive bounded excerpts.") }
        _ = try await web.evaluateJavaScript("document.querySelector('.note-quotation summary').click()")
        try await action(["op":"native","action":"selectNote","id":note.id.uuidString], web:web)
        guard (try await web.evaluateJavaScript("document.querySelector('.note-quotation')?.open")) as? Bool == true else { throw ValidationError("A passive note update collapsed the selected quotation.") }
        try await action(["op":"native","action":"selectNote","id":second.id.uuidString], web:web)
        guard (try await web.evaluateJavaScript("document.querySelector('.note-quotation')?.open")) as? Bool == false else { throw ValidationError("Quotation expansion leaked to a different note.") }
        try await action(["op":"native","action":"notesQuery","value":"UNIQUE QUOTATION"], web:web)
        guard (try await web.evaluateJavaScript("document.querySelector('.note-list button')?.dataset.id")) as? String == second.id.uuidString else { throw ValidationError("Quotation text beyond its list excerpt could not be found.") }
        try await action(["op":"native","action":"notesQuery","value":"unique body phrase"], web:web)
        // A repeated synchronization must reuse the match without losing it.
        try await action(["op":"native","action":"selectNote","id":second.id.uuidString], web:web)
        guard (try await web.evaluateJavaScript("document.querySelector('.note-list button')?.dataset.id")) as? String == second.id.uuidString else { throw ValidationError("Note content search lost its cached result.") }
        try app.updateModuleNote(id:second.id, profileID:model.session.profileID, field:"text", value:"Changed body")
        try await action(["op":"native","action":"selectNote","id":second.id.uuidString], web:web)
        guard (try await web.evaluateJavaScript("document.querySelectorAll('.note-list button').length")) as? Int == 0 else { throw ValidationError("Edited note content retained a stale search match.") }
        try app.updateModuleNote(id:second.id, profileID:model.session.profileID, field:"text", value:"Unique body phrase restored")
        try await action(["op":"native","action":"selectNote","id":second.id.uuidString], web:web)
        guard (try await web.evaluateJavaScript("document.querySelector('.note-list button')?.dataset.id")) as? String == second.id.uuidString else { throw ValidationError("Edited note content did not become searchable.") }
        app.library.notes = original
        try await action(["op":"native","action":"notesQuery","value":""], web:web)
        try await action(["op":"native","action":"selectNote","id":note.id.uuidString], web:web)
    }
    private static func verifyLargeNoteProjection(app:AppState,model:BrowserModel,web:WKWebView) async throws {
        let original=app.library.notes,configuration=model.configuration
        defer {app.library.notes=original;app.applyConfiguration(configuration,to:model.session.spaceID)}
        var withNotes=configuration;withNotes.layout.secondaryPanel="notes"
        app.applyConfiguration(withNotes,to:model.session.spaceID)
        let text=String(repeating:"漢",count:200_000)
        var latest=UUID()
        for index in 0..<40 {
            var note=Note(profileID:model.session.profileID,title:"Large note \(index)",text:text)
            note.spaceID=model.session.spaceID;latest=note.id;app.library.notes.append(note)
        }
        try await action(["op":"screen","value":"library","section":"bookmarks"],web:web)
        try await action(["op":"escape"],web:web)
        try await action(["op":"native","action":"selectNote","id":latest.uuidString],web:web)
        let next=(try await web.evaluateJavaScript("!!document.querySelector('.workspace-panel [data-action=libraryPage][data-value=\"1\"]:not(:disabled)')")) as? Bool == true
        guard next else {throw ValidationError("A saved Notes panel lost its own pagination after visiting Bookmarks.")}
        try await action(["op":"native","action":"libraryPage","value":"1"],web:web)
        let length=(try await web.evaluateJavaScript("document.querySelector('.workspace-panel textarea')?.value.length")) as? Int
        guard length==200_000,model.hasPage else {throw ValidationError("Large valid notes broke the shell projection.")}
        app.library.notes=original
        try await action(["op":"section","value":"notes"],web:web)
    }
    private static func unwrapSplit(_ model:BrowserModel) throws -> TabSplit {
        guard let pair=model.session.split else {throw ValidationError("The research split is missing.")};return pair
    }
    static func verifyPageGeometry(window:NSWindow, model:BrowserModel, output:URL) async throws {
        let web=try await waitForShell(in:window)
        try await action(["op":"screen","value":"browse"],web:web)
        try await Task.sleep(for:.milliseconds(200))
        let geometry = try await web.evaluateJavaScript("(()=>{const p=document.querySelector('.native-page[data-page=\"\(model.session.selectedTabID.uuidString)\"]');if(!p)return null;const r=p.getBoundingClientRect();return {width:r.width,height:r.height,x:r.x,y:r.y};})()") as? [String:Double]
        // The research check deliberately retains split panes and a panel.
        // Validate the selected pane, including supported narrow comparisons.
        guard let geometry, geometry["width",default:0]>100, geometry["height",default:0]>=250,
              model.activeWebTab.nativeView.window === window,
              abs(model.activeWebTab.nativeView.bounds.width-geometry["width",default:0]) < 3,
              abs(model.activeWebTab.nativeView.bounds.height-geometry["height",default:0]) < 3 else { throw ValidationError("The native page does not match the Rust-rendered page region.") }
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
    private static func evaluatePage(_ page:BrowserEngineTab,_ expression:String, line:UInt = #line) async throws -> String {
        print("Neutrino page evaluation: engine=\(page.engineID.rawValue), source=RustShellAcceptance:\(line)")
        if let web=page as? WebTab { return (try await web.webView.evaluateJavaScript(expression)) as? String ?? "" }
        if let chrome=page as? ChromiumTab {
            let data=try await chrome.request("Runtime.evaluate",parameters:["expression":expression,"returnByValue":true],line:line)
            let object=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            guard object?["exceptionDetails"]==nil else {throw ValidationError("The fixture JavaScript failed: " + String(describing:object?["exceptionDetails"]))}
            return (object?["result"] as? [String:Any])?["value"] as? String ?? ""
        }
        throw ValidationError("The editor input test requires a website engine.")
    }
}
