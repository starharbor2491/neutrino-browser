// SPDX-License-Identifier: MPL-2.0
import AppKit
import NeutrinoCore
import Testing
@preconcurrency import WebKit

@testable import NeutrinoApp

extension NativeIntegrationTests {
  @Suite(.serialized) @MainActor struct WorkspaceIntegrationTests {
    @Test func sharedTabMovesTheExistingDocumentAndRewiresItsCallbacks() async throws {
      let (app, directory) = try await fixture()
      let first = BrowserModel(app: app, isPrivate: false)
      let second = BrowserModel(app: app, isPrivate: false)
      defer {
        first.closeWindow()
        second.closeWindow()
        try? FileManager.default.removeItem(at: directory)
      }
      let tabID = first.session.selectedTabID
      let page = try #require(first.activeWebTab as? WebTab)
      page.webView.loadHTMLString(
        "<title>Retained page</title><input id='form' value='unsaved work'><script>window.ownershipMarker=73</script>",
        baseURL: URL(string: "https://example.com"))
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      while page.webView.title != "Retained page" {
        guard ContinuousClock.now < deadline else {
          throw ValidationError("The test page did not load.")
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      second.selectTab(tabID)
      #expect(second.activeWebTab === page)
      #expect(first.activeWebTab !== page)
      #expect(app.tabOwnership.owner(of: tabID) == second.session.id)
      let value =
        try await page.webView.evaluateJavaScript(
          "document.getElementById('form').value + ':' + window.ownershipMarker") as? String
      #expect(value == "unsaved work:73")
      first.addressEditing = true
      first.address = "unfinished search"
      second.newTab(engine: .webkit)
      #expect(first.session.tabs.map(\.id) == second.session.tabs.map(\.id))
      #expect(first.address == "unfinished search")
      first.selectTab(tabID)
      #expect(first.activeWebTab === page)
      #expect(app.tabOwnership.owner(of: tabID) == first.session.id)
    }
    @Test func switchingSpacesKeepsTheLiveDocumentAndASeparateSetup() async throws {
      let (app, directory) = try await fixture()
      let browser = BrowserModel(app: app, isPrivate: false)
      defer {
        browser.closeWindow()
        try? FileManager.default.removeItem(at: directory)
      }
      let firstSpace = try #require(browser.session.spaceID)
      let firstTab = browser.session.selectedTabID
      let page = browser.activeWebTab
      let work = try #require(app.createSpace(name: "Work", profileID: browser.profile.id))
      var setup = Configuration()
      setup.layout.tabs = .trailing
      app.applyConfiguration(setup, to: work)
      browser.switchSpace(work)
      #expect(browser.configuration.layout.tabs == .trailing)
      #expect(browser.activeWebTab !== page)
      browser.switchSpace(firstSpace)
      browser.selectTab(firstTab)
      #expect(browser.activeWebTab === page)
      #expect(browser.configuration.layout.tabs == .leading)
    }
    @Test func deletingProfileStopsCachedPagesFromInactiveSpaces() async throws {
      let (app, directory) = try await fixture()
      let browser = BrowserModel(app: app, isPrivate: false)
      defer {
        browser.closeWindow()
        try? FileManager.default.removeItem(at: directory)
      }
      let oldProfile = browser.profile.id
      let oldTab = browser.session.selectedTabID
      _ = browser.activeWebTab
      let work = Profile(name: "Work")
      app.library.profiles.append(work)
      let space = try #require(app.createSpace(name: "Work", profileID: work.id))
      browser.switchSpace(space)
      browser.disposeEngineTabs(profileID: oldProfile)
      #expect(app.tabOwnership.owner(of: oldTab) == nil)
    }
    @Test func closingAPageInAnInactiveSpaceRemovesItsCanonicalTab() async throws {
      let (app, directory) = try await fixture()
      let browser = BrowserModel(app: app, isPrivate: false)
      defer {
        browser.closeWindow()
        try? FileManager.default.removeItem(at: directory)
      }
      let originalSpace = try #require(browser.session.spaceID)
      let originalTab = browser.session.selectedTabID
      let page = browser.activeWebTab
      let other = try #require(app.createSpace(name: "Other", profileID: browser.profile.id))
      browser.switchSpace(other)
      page.onClose?()
      #expect(app.tabOwnership.owner(of: originalTab) == nil)
      let original = try #require(app.library.spaces?.first { $0.id == originalSpace })
      #expect(!original.tabs.contains { $0.id == originalTab })
      #expect(browser.session.spaceID == other)
      browser.switchSpace(originalSpace)
      #expect(browser.session.tabs == original.tabs)
    }
    private func fixture() async throws -> (AppState, URL) {
      _ = NSApplication.shared
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "NeutrinoWorkspaceTest-" + UUID().uuidString)
      let app = AppState(directory: directory)
      await app.load()
      try #require(app.ready)
      app.library.profiles[0].engineID = .webkit
      app.library.spaces?[0].tabs[0].engineID = .webkit
      return (app, directory)
    }
  }
}
