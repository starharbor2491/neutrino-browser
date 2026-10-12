// SPDX-License-Identifier: MPL-2.0
import AppKit
import NeutrinoCore
import Testing
@preconcurrency import WebKit
@testable import NeutrinoApp

extension NativeIntegrationTests {
  @Suite(.serialized) @MainActor struct RustShellNativeTests {
    @Test func aLargeLibraryCanOpenAndAnImmediateNoteDismissalSaves() async throws {
      _ = NSApplication.shared
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NeutrinoRustShell-" + UUID().uuidString)
      let app = AppState(directory: directory); await app.load()
      app.library.profiles[0].engineID = .webkit
      app.library.preferences.completedOnboarding = true
      let profile = app.library.profiles[0].id
      app.library.notes = (0..<25).map { Note(profileID: profile, title: "Note \($0)", text: String(repeating: "n", count: 100_000)) }
      let model = BrowserModel(app: app, isPrivate: false)
      let coordinator = RustShellCoordinator(app: app, model: model, downloadCenter: nil, previewStep: nil, openWindow: nil)
      let window = NSWindow(contentRect: NSRect(x:0,y:0,width:1000,height:720),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
      window.contentView = coordinator.container; window.makeKeyAndOrderFront(nil)
      defer { coordinator.stop(); model.closeWindow(); window.orderOut(nil); try? FileManager.default.removeItem(at:directory) }
      let web = try await RustShellAcceptance.waitForShell(in:window)
      try await RustShellAcceptance.action(["op":"screen","value":"library","section":"notes"],web:web)
      let note = try #require(app.library.notes.first)
      try await RustShellAcceptance.action(["op":"native","action":"selectNote","id":note.id.uuidString],web:web)
      _ = try await web.evaluateJavaScript("const e=document.querySelector('textarea[data-note]');e.focus();e.value='Kept after Escape';e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));")
      try await Task.sleep(for:.milliseconds(180))
      #expect(app.library.notes.first?.text == "Kept after Escape")
      #expect((try await web.evaluateJavaScript("!document.querySelector('.library-panel')")) as? Bool == true)
    }
    @Test func auxiliaryDownloadsNeverProjectTheDefaultLibrary() async throws {
      _ = NSApplication.shared
      let directory=FileManager.default.temporaryDirectory.appendingPathComponent("NeutrinoDownloadsScope-"+UUID().uuidString)
      let app=AppState(directory:directory);await app.load()
      app.library.preferences.completedOnboarding=true
      app.library.notes=[Note(profileID:app.library.profiles[0].id,title:"Private sentinel",text:"must never appear")]
      let center=DownloadCenter()
      let coordinator=RustShellCoordinator(app:app,model:nil,downloadCenter:center,previewStep:nil,openWindow:nil)
      let window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:520),styleMask:[.titled],backing:.buffered,defer:false)
      window.contentView=coordinator.container;window.makeKeyAndOrderFront(nil)
      defer {coordinator.stop();window.orderOut(nil);try? FileManager.default.removeItem(at:directory)}
      let web=try await RustShellAcceptance.waitForShell(in:window)
      try await RustShellAcceptance.action(["op":"section","value":"notes"],web:web)
      try await RustShellAcceptance.action(["op":"native","action":"createNote"],web:web)
      #expect(app.library.notes.count==1)
      #expect((try await web.evaluateJavaScript("!!document.querySelector('.downloads-window') && !document.body.innerText.includes('Private sentinel') && !document.querySelector('.library-tabs')")) as? Bool == true)
    }
    @Test func cachedContainerReparentsALiveViewAfterRoundTrip() {
      let page = NSView(frame:NSRect(x:0,y:0,width:400,height:300))
      let first = EngineViewContainer(page:page)
      let second = EngineViewContainer(page:page)
      #expect(page.superview === second)
      first.mount(page)
      #expect(page.superview === first)
      second.unmount()
      #expect(page.superview === first)
    }
    @Test func FoundationUsesTheValidatedCanonicalAIEndpoint() throws {
      let malicious = AIConfiguration(provider:.openAI,endpoint:"https://api.openai.com\\@attacker.example/v1",model:"m")
      #expect(throws:(any Error).self) { try malicious.validatedEndpoint() }
      let valid = AIConfiguration(provider:.openAI,endpoint:"HTTPS://API.OPENAI.COM:443/v1",model:"m")
      #expect(try valid.validatedEndpoint().absoluteString == "https://api.openai.com/v1")
    }
  }
}
