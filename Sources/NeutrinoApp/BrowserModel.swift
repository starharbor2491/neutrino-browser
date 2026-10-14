// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
@preconcurrency import WebKit
import NeutrinoCore

@MainActor
final class BrowserModel: ObservableObject {
    var visibleEngineTabs: [(id: UUID, page: BrowserEngineTab)] {
        let ids = session.split.map { [$0.first, $0.second] } ?? [session.selectedTabID]
        return ids.map { ($0, webTab($0)) }
    }
    var shellAction: (([String: Any]) -> Void)?
    var stopInterface: (() async -> Void)?
    @Published var session: WindowSession {
        didSet {
            guard !restoringFrozenSession else { return }
            if app.finalQuitDataFrozen {
                restoringFrozenSession = true
                session = oldValue
                restoringFrozenSession = false
                return
            }
            if !isPrivate && !isClosed && !receivingSharedTabs { app.updateSession(session) }
        }
    }
    private var restoringFrozenSession = false
    private var receivingSharedTabs = false
    @Published private(set) var isClosed = false
    @Published var panel: BrowserPanel? = nil
    @Published var address = ""
    var addressEditing = false
    @Published var focusMode = false { didSet { if !focusMode { focusHiddenComponents = []; focusProviderID = nil } } }
    @Published var focusHiddenComponents = Set<String>()
    var focusProviderID: String?
    func enterFocus() {
        app.perform {
            let requested = try app.requestedFocusPresentation()
            focusHiddenComponents = requested.hiddenComponents; focusProviderID = requested.moduleID
            focusMode = !requested.hiddenComponents.isEmpty
        }
    }
    func exitFocus() {
        if focusMode, app.installedModules.contains(where: { $0.id == focusProviderID && $0.enabled }) {
            app.perform { _ = try app.behaviorResult(.focusMode, event: "exit") }
        }
        focusMode = false
    }
    @Published var sheet: BrowserSheet?
    private struct ClosedTabContext: Hashable { let profileID: UUID; let spaceID: UUID? }
    private var closedTabStacks: [ClosedTabContext: [BrowserTab]] = [:]
    var closedTabs: [BrowserTab] {
        get { closedTabStacks[ClosedTabContext(profileID: session.profileID, spaceID: session.spaceID)] ?? [] }
        set { closedTabStacks[ClosedTabContext(profileID: session.profileID, spaceID: session.spaceID)] = newValue; objectWillChange.send() }
    }
    let isPrivate: Bool
    let app: AppState
    private let privateDownloads = DownloadCenter()
    var downloads: DownloadCenter {
        if isPrivate { return privateDownloads }
        if let existing = app.profileDownloads[session.profileID] { return existing }
        let center = DownloadCenter(); app.profileDownloads[session.profileID] = center; return center
    }
    private var webTabs: [UUID: BrowserEngineTab] = [:]
    private var tabProfiles: [UUID: UUID] = [:]
    func cachedEngineTab(_ id: UUID, profileID: UUID) -> BrowserEngineTab? {
        guard !isPrivate, tabProfiles[id] == profileID else { return nil }
        return webTabs[id]
    }
    private var movedTabPlaceholders: [UUID: BrowserEngineTab] = [:]
    private var spacePresentations: [UUID: WindowSession] = [:]
    var space: BrowserSpace? { app.library.spaces?.first { $0.id == session.spaceID } }
    var configuration: Configuration { app.previewConfiguration ?? app.library.configuration(for: session.spaceID) }
    private var privateDataStore: WKWebsiteDataStore?
    var selectedTab: BrowserTab { session.tabs.first(where: { $0.id == session.selectedTabID }) ?? session.tabs[0] }
    var profile: Profile { app.library.profiles.first(where: { $0.id == session.profileID }) ?? app.library.profiles[0] }
    var activeWebTab: BrowserEngineTab { webTab(session.selectedTabID) }
    var hasPage: Bool { selectedTab.url != nil }
    var chromePageSnapshots: [String:[[String:Any]]] {
        guard let engine = webTabs[session.selectedTabID] as? ChromiumTab, engine.interfacePages.count > 1 else { return [:] }
        // Only the current group's subrows are expanded. Labels are display
        // metadata; native membership/selection always use the original IDs.
        let pages = engine.interfacePages.prefix(200).map { item in
            ["id":item["id"] as? Int ?? 0,"selected":item["selected"] as? Bool ?? false,
             "title":String((item["title"] as? String ?? "").prefix(128)),
             "url":String((item["url"] as? String ?? "").prefix(1024))] as [String:Any]
        }
        return [session.selectedTabID.uuidString:pages]
    }
    var chromePageCounts: [String:Int] {
        Dictionary(uniqueKeysWithValues:session.tabs.compactMap { tab in
            guard let engine = webTabs[tab.id] as? ChromiumTab else { return nil }
            return (tab.id.uuidString,engine.interfacePages.count)
        })
    }
    var hasNativeTabs: Bool { webTabs[session.selectedTabID]?.hasNativeNavigationChrome == true }
    var bookmarks: [Bookmark] { app.library.bookmarks.filter { $0.profileID == session.profileID } }
    init(app: AppState, isPrivate: Bool) {
        self.app = app; self.isPrivate = isPrivate; session = app.claimSession(privateBrowsing: isPrivate)
        let engine = app.library.profiles.first { $0.id == session.profileID }?.engineID ?? .chromium
        for i in session.tabs.indices where session.tabs[i].engineID == nil { session.tabs[i].engineID = engine }
        if isPrivate {
            privateDataStore = .nonPersistent()
            ChromiumRuntime.shared.beginPrivateSession(session.id)
        }
        address = selectedTab.url?.absoluteString ?? ""
        app.registerWindow(self)
    }
    func webTab(_ id: UUID) -> BrowserEngineTab {
        if app.deletingProfileIDs.contains(session.profileID) { return UnavailableEngineTab(engine: selectedTab.engineID ?? .chromium, reason: "This profile is being deleted.") }
        if app.profilesAwaitingWebsiteDataRemoval.contains(session.profileID) {
            return UnavailableEngineTab(engine: session.tabs.first(where: { $0.id == id })?.engineID ?? .chromium,
                reason: "Website data removal is pending for this profile. Quit and reopen Neutrino to retry before browsing.")
        }
        if let cached = webTabs[id] { return cached }
        if !isPrivate, let owner = app.tabOwnership.owner(of: id), owner != session.id {
            if let placeholder = movedTabPlaceholders[id] { return placeholder }
            let placeholder = UnavailableEngineTab(engine: selectedTab.engineID ?? .chromium, reason: "This live tab is open in another window. Select the tab to move it here.")
            movedTabPlaceholders[id] = placeholder; return placeholder
        }
        let engine = session.tabs.first(where: { $0.id == id })?.engineID ?? .chromium
        // Quitting may be cancelled. Keep this placeholder out of the cache so
        // live tabs can be recreated normally after AppKit keeps the app open.
        if app.terminating { return UnavailableEngineTab(engine: engine, reason: "Neutrino is closing its browsing engines.") }
        guard !isClosed else {
            let tab = UnavailableEngineTab(engine: engine, reason: "This browser window is closed.")
            webTabs[id] = tab; return tab
        }
        let tab: BrowserEngineTab
        if engine == .chromium {
            do { tab = try ChromiumRuntime.shared.makeTab(profileID: session.profileID, privateSessionID: isPrivate ? session.id : nil, dataDirectory: app.dataDirectory, downloads: downloads) }
            catch { return UnavailableEngineTab(engine: engine, reason: error.localizedDescription) }
        } else {
            let dataStore = privateDataStore ?? app.webKitDataStore(profileID: session.profileID)
            tab = WebTab(dataStore: dataStore, downloads: downloads, profileID: session.profileID)
        }
        attach(tab, id: id)
        if engine == .chromium, let pages = session.tabs.first(where: { $0.id == id })?.chromiumPages, !pages.isEmpty {
            tab.restoreChromiumSessionPages(ChromiumSessionPage.normalized(pages))
        } else if let url = session.tabs.first(where: { $0.id == id })?.url { tab.load(url) }
        return tab
    }
    private func attach(_ tab: BrowserEngineTab, id: UUID) {
        let sourceProfileID = session.profileID, sourceSpaceID = session.spaceID
        tabProfiles[id] = sourceProfileID
        if !isPrivate { app.tabOwnership.claim(id, in: session.id) }
        tab.onChange = { [weak self, weak tab] finished in
            guard let self, !self.isClosed, !self.app.finalQuitDataFrozen, !self.app.deletingProfileIDs.contains(sourceProfileID), self.app.library.profiles.contains(where: { $0.id == sourceProfileID }), let tab else { return }
            guard let index = self.session.tabs.firstIndex(where: { $0.id == id }) else {
                if !self.isPrivate { self.app.recordBackgroundTab(tab, id: id, spaceID: sourceSpaceID, profileID: sourceProfileID, finished: finished) }
                return
            }
            if let pages = tab.chromiumSessionPages {
                let saved: [ChromiumSessionPage]? = tab.isShowingStartPage && pages.count == 1 ? nil : ChromiumSessionPage.normalized(pages)
                if self.session.tabs[index].chromiumPages != saved { self.session.tabs[index].chromiumPages = saved }
            }
            if tab.isShowingStartPage {
                self.session.tabs[index].url = nil
                self.session.tabs[index].title = "New tab"
                if self.session.selectedTabID == id && !self.addressEditing { self.address = "" }
                return
            }
            if let url = tab.url, AddressResolver.isWebURL(url) || url.scheme == "blob" || url.absoluteString == "about:blank" ||
                (tab.engineID == .chromium && ["chrome", "chrome-extension"].contains(url.scheme ?? "")) {
                if finished { tab.updateSiteIcon(for: url) }
                self.session.tabs[index].faviconDataURL = tab.faviconDataURL
                self.session.tabs[index].url = url
                self.session.tabs[index].title = boundedPageTitle(tab.title ?? url.host ?? "Website")
                if self.session.selectedTabID == id && !self.addressEditing { self.address = url.absoluteString }
                if finished && !self.isPrivate && AddressResolver.isWebURL(url) {
                    self.app.addHistory(url: url, title: self.session.tabs[index].title, profileID: self.session.profileID)
                }
            }
        }
        tab.onCreateWindow = { [weak self] child, url in
            guard let self, !self.isClosed, !self.app.terminating,
                  !self.app.deletingProfileIDs.contains(sourceProfileID),
                  !self.app.profilesAwaitingWebsiteDataRemoval.contains(sourceProfileID),
                  self.app.library.profiles.contains(where: { $0.id == sourceProfileID }),
                  self.session.tabs.count < 200 else { return false }
            if let sourceSpaceID, self.session.spaceID != sourceSpaceID { self.switchSpace(sourceSpaceID) }
            let descriptor = BrowserTab(url: url ?? URL(string: "about:blank"), engineID: child.engineID)
            self.attach(child, id: descriptor.id)
            self.session.tabs.append(descriptor); self.selectTab(descriptor.id)
            _ = self.session.setParent(descriptor.id, to: id)
            return true
        }
        tab.onClose = { [weak self] in
            guard let self else { return }
            if self.session.tabs.contains(where: { $0.id == id }) { self.completeCloseTab(id) }
            else if let sourceSpaceID { self.app.closeBackgroundTab(id, spaceID: sourceSpaceID) }
        }
        tab.onNotice = { [weak self] message in self?.app.notice = message }
        tab.onActivate = { [weak self] in
            guard let self, !self.isClosed, self.session.selectedTabID != id,
                  self.session.split?.contains(id) == true else { return }
            self.selectTab(id)
        }
        tab.onBrowserCommand = { [weak self, weak tab] command in
            guard let self, !self.isClosed, !self.app.finalQuitDataFrozen, let tab else { return }
            if self.session.selectedTabID != id { self.selectTab(id) }
            switch command {
            case "newTab":
                if let action = self.shellAction { action(["op":"newTab"]) }
                else { self.newTab(); NotificationCenter.default.post(name: .neutrinoFocusAddress, object: self.session.id) }
            case "reopenTab": self.reopenClosedTab()
            case "nextTab": self.selectRelativeTab(1)
            case "previousTab": self.selectRelativeTab(-1)
            case "quickNavigation": self.shellAction?(["op":"palette"])
            case "focusAddress": NotificationCenter.default.post(name: .neutrinoFocusAddress, object: self.session.id)
            case "closeTab":
                if let action = self.shellAction { action(["op":"closeCurrent"]) }
                else { self.closeTab(id) }
            case "closeWindow": tab.nativeView.window?.performClose(nil)
            case "newWindow": NotificationCenter.default.post(name: .neutrinoOpenBrowserWindow, object: self.session.id, userInfo: ["private": false])
            case "privateWindow": NotificationCenter.default.post(name: .neutrinoOpenBrowserWindow, object: self.session.id, userInfo: ["private": true])
            case "quit": NSApp.terminate(nil)
            case "downloads": self.togglePanel(.downloads)
            default: break
            }
        }
        tab.allowPopups = { [weak self] in self?.app.library.preferences.blockPopups == false }
        tab.blockingEnabled = app.library.preferences.blockTrackers != false
        webTabs[id] = tab
    }
    func updatePopupPolicy() { webTabs.values.forEach { $0.updatePopupPolicy() } }
    func updateBlockingPolicy() { webTabs.values.forEach { $0.blockingEnabled = app.library.preferences.blockTrackers != false } }
    func navigate(_ input: String) {
        guard !isClosed, !app.finalQuitDataFrozen else { return }
        guard let url = AddressResolver.resolve(input, search: app.library.preferences.search) else {
            app.notice = "Enter a website address or search. Only HTTP and HTTPS addresses are supported."; return
        }
        let tab = activeWebTab
        session.tabs[session.tabs.firstIndex(where: { $0.id == session.selectedTabID })!].url = url
        address = url.absoluteString
        tab.load(url)
    }
    func showStartPage() {
        guard !isClosed, !app.finalQuitDataFrozen, let index = session.tabs.firstIndex(where: { $0.id == session.selectedTabID }) else { return }
        // Stop the old document while retaining its engine, website store,
        // back history and any transfers already owned by the adapter.
        let tab = activeWebTab
        tab.showStartPage()
        // Both engines retain their document history underneath Neutrino's
        // own start surface.
        let startURL = tab.isShowingStartPage ? nil : tab.url
        session.tabs[index].url = startURL
        session.tabs[index].title = tab.isShowingStartPage ? "New tab" : boundedPageTitle(tab.title ?? "New tab")
        address = startURL?.absoluteString ?? ""; addressEditing = false
    }
    func performTabCommand(_ command: NativeTabCommand) {
        guard !isClosed, !app.finalQuitDataFrozen else { return }
        if activeWebTab.performNativeTabCommand(command) { return }
        switch command {
        case .new:
            shellAction?(["op": "newTab"])
        case .close:
            if let action = shellAction { action(["op":"closeCurrent"]) }
            else { closeTab(session.selectedTabID) }
        case .reopen: reopenClosedTab()
        case .previous: selectRelativeTab(-1)
        case .next: selectRelativeTab(1)
        }
    }
    func newTab(url: URL? = nil, parentID: UUID? = nil, engine: BrowserEngineID? = nil) {
        guard !isClosed, !app.finalQuitDataFrozen else { return }
        if let url, !AddressResolver.isWebURL(url) { app.notice = "This page cannot be reopened in a separate browsing context."; return }
        if let parentID, !session.tabs.contains(where: { $0.id == parentID }) || session.ancestors(of: parentID).count >= 8 {
            app.notice = "Tab trees support up to eight levels. Open this page as a top-level tab instead."; return
        }
        guard session.tabs.count < 200 else { app.notice = "This window has 200 tabs. Close a tab or open another window."; return }
        let tab = BrowserTab(url: url, engineID: engine ?? profile.engineID ?? .chromium)
        session.tabs.append(tab)
        if let parentID { _ = session.setParent(tab.id, to: parentID) }
        selectTab(tab.id)
    }
    func selectTab(_ id: UUID) {
        guard !app.finalQuitDataFrozen, session.tabs.contains(where: { $0.id == id }) else { return }
        moveLiveTabHere(id)
        if let index = session.tabs.firstIndex(where: { $0.id == id }) { session.tabs[index].lastUsedAt = Date() }
        let previousWindow = webTabs[session.selectedTabID]?.nativeView.window
        session.selectTab(id); address = selectedTab.url?.absoluteString ?? ""
        // A Chrome child can leave the parent's field responder in its other
        // split pane. Explicit selection must release that stale page focus,
        // including when the selected blank pane has no mounted native view.
        guard session.split != nil else { return }
        let tab = webTabs[id]
        if let window = tab?.nativeView.window ?? previousWindow,
           let current = window.firstResponder as? NSView,
           webTabs.contains(where: { entry in
               entry.key != id && (current === entry.value.nativeView || current.isDescendant(of: entry.value.nativeView))
           }) {
            window.makeFirstResponder(nil)
        }
        if let tab, let window = tab.nativeView.window {
            if let current = window.firstResponder as? NSView, current === tab.nativeView || current.isDescendant(of: tab.nativeView) { return }
            tab.focus()
        }
    }
    func requestCloseTab(_ id: UUID) { closeTab(id) }
    func closeTab(_ id: UUID) {
        guard !isClosed, !app.finalQuitDataFrozen, session.tabs.contains(where: { $0.id == id }) else { return }
        moveLiveTabHere(id)
        guard let page = webTabs[id] else { completeCloseTab(id); return }
        if page.hasActiveDownloads {
            let alert = NSAlert(); alert.messageText = "Cancel this tab’s downloads?"
            alert.informativeText = "Keep the tab open until its downloads finish, or cancel them and close the tab."
            alert.addButton(withTitle: "Keep tab open"); alert.addButton(withTitle: "Cancel downloads and close")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        // Keep the live adapter and canonical descriptor until the engine confirms
        // closure. A site's beforeunload Cancel leaves both intact.
        page.requestClose()
    }
    private func completeCloseTab(_ id: UUID) {
        guard !app.finalQuitDataFrozen, let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        captureChromiumSessions()
        let closing = session.tabs[index]
        if closing.url.map(AddressResolver.isWebURL) == true || closing.chromiumPages?.contains(where: { $0.url != nil }) == true {
            closedTabs.append(closing); if closedTabs.count > 20 { closedTabs.removeFirst() }
        }
        if !isPrivate, let owner = app.tabOwnership.owner(of: id), owner != session.id {
            app.windows[owner]?.model?.takeLiveTab(id)?.dispose()
            app.tabOwnership.release(id, from: owner)
        }
        webTabs.removeValue(forKey: id)?.dispose()
        tabProfiles.removeValue(forKey: id)
        app.tabOwnership.release(id, from: session.id)
        for i in session.tabs.indices where session.tabs[i].parentID == id { session.tabs[i].parentID = closing.parentID }
        let otherPane = session.split.map { $0.first == id ? $0.second : $0.first }
        if session.split?.contains(id) == true { session.split = nil; session.splitSuppressed = true }
        session.tabs.remove(at: index)
        if session.tabs.isEmpty { session.tabs = [BrowserTab(engineID: profile.engineID ?? .chromium)] }
        if session.selectedTabID == id { selectTab(otherPane ?? session.tabs[min(index, session.tabs.count - 1)].id) }
    }
    func reopenClosedTab() {
        guard !app.finalQuitDataFrozen, session.tabs.count < 200, var tab = closedTabs.popLast() else { return }
        tab.id = UUID(); tab.parentID = nil; tab.collapsed = nil
        if let folder = tab.folderID, space?.folders.contains(where: { $0.id == folder }) != true { tab.folderID = nil }
        if tab.pinned {
            session.tabs.insert(tab, at: session.tabs.firstIndex(where: { !$0.pinned }) ?? session.tabs.endIndex)
        } else { session.tabs.append(tab) }
        selectTab(tab.id)
    }
    func selectRelativeTab(_ offset: Int) {
        guard let index = session.tabs.firstIndex(where: { $0.id == session.selectedTabID }) else { return }
        selectTab(session.tabs[(index + offset + session.tabs.count) % session.tabs.count].id)
    }
    func moveTab(_ id: UUID, by offset: Int) {
        guard !app.finalQuitDataFrozen, let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        if configuration.layout.treeTabs == true {
            let siblings = session.tabs.filter { $0.parentID == session.tabs[index].parentID && $0.pinned == session.tabs[index].pinned }
            guard let sibling = siblings.firstIndex(where: { $0.id == id }), siblings.indices.contains(sibling + offset),
                  let target = session.tabs.firstIndex(where: { $0.id == siblings[sibling + offset].id }) else { return }
            session.tabs.swapAt(index, target)
        } else if session.tabs.indices.contains(index + offset), session.tabs[index].pinned == session.tabs[index + offset].pinned { session.tabs.swapAt(index, index + offset) }
    }
    @discardableResult func moveTab(_ id: UUID, before target: UUID) -> Bool {
        guard !app.finalQuitDataFrozen, id != target, let from = session.tabs.firstIndex(where: { $0.id == id }), let to = session.tabs.firstIndex(where: { $0.id == target }) else { return false }
        guard session.tabs[from].pinned == session.tabs[to].pinned else { return false }
        if configuration.layout.treeTabs == true && session.tabs[from].parentID != session.tabs[to].parentID {
            guard session.setParent(id, to: session.tabs[to].parentID) else { return false }
        }
        let item = session.tabs.remove(at: from); session.tabs.insert(item, at: from < to ? to - 1 : to)
        return true
    }
    func pinTab(_ id: UUID) {
        guard !app.finalQuitDataFrozen, let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        session.tabs[index].pinned.toggle()
        if session.tabs[index].pinned { session.tabs[index].parentID = nil }
        session.tabs = session.tabs.filter(\.pinned) + session.tabs.filter { !$0.pinned }
    }
    func synchronizeSplit(force: Bool = false) {
        // A layout preview must not create or persist browsing tabs.
        guard !isClosed, !app.finalQuitDataFrozen, app.previewConfiguration == nil else { return }
        if configuration.layout.split != nil {
            if force { session.splitSuppressed = nil }
            if session.splitSuppressed != true { session.enableSplit(defaultEngine: profile.engineID ?? .chromium) }
        } else { session.split = nil; session.splitSuppressed = nil }
    }
    func beginSplit(_ axis: SplitAxis) {
        guard !app.finalQuitDataFrozen else { return }
        var config = configuration; config.layout.split = axis
        app.applyConfiguration(config, to: session.spaceID)
        synchronizeSplit(force: true)
    }
    func endSplit() {
        guard !app.finalQuitDataFrozen else { return }
        session.split = nil; session.splitSuppressed = true
    }
    func selectOtherPane() {
        guard let pair = session.split else { return }
        selectTab(pair.first == session.selectedTabID ? pair.second : pair.first)
    }
    func updateFocusedTab(_ responder: NSResponder?) {
        guard let pair = session.split, let view = responder as? NSView else { return }
        for id in [pair.first, pair.second] where id != session.selectedTabID {
            if let tab = webTabs[id], view === tab.nativeView || view.isDescendant(of: tab.nativeView) {
                selectTab(id); return
            }
        }
    }
    func toggleBranch(_ id: UUID) {
        guard !app.finalQuitDataFrozen, let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        session.tabs[index].collapsed = session.tabs[index].collapsed != true
        if session.tabs[index].collapsed == true && session.ancestors(of: session.selectedTabID).contains(id) { selectTab(id) }
    }
    func switchProfile(_ id: UUID) {
        if !isPrivate, let space = app.library.spaces?.first(where: { $0.profileID == id }) { switchSpace(space.id); return }
        guard id != session.profileID, app.library.profiles.contains(where: { $0.id == id }) else { return }
        guard app.deletingProfileIDs.isDisjoint(with: [id, session.profileID]) else { app.notice = "Wait for profile deletion to finish before switching profiles."; return }
        let alert = NSAlert(); alert.messageText = "Switch profile?"
        alert.informativeText = "Open pages will reload in the selected profile. Sign-ins stay separate. Unsaved page work may be lost."
        alert.addButton(withTitle: "Switch profile"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        changeProfile(id)
    }
    func changeProfile(_ id: UUID) {
        if !isPrivate, let profile = app.library.profiles.first(where: { $0.id == id }) {
            let spaceID = app.library.spaces?.first(where: { $0.profileID == id })?.id ?? app.createSpace(name: profile.name, profileID: id)
            if let spaceID { switchSpace(spaceID) }; return
        }
        guard !isClosed, !app.finalQuitDataFrozen, app.library.profiles.contains(where: { $0.id == id }) else { return }
        guard app.deletingProfileIDs.isDisjoint(with: [id, session.profileID]) else { app.notice = "Wait for profile deletion to finish before switching profiles."; return }
        webTabs.values.forEach { $0.dispose() }; webTabs.removeAll(); closedTabs.removeAll()
        if isPrivate { ChromiumRuntime.shared.releasePrivateProfile(session.profileID, sessionID: session.id) }
        session.profileID = id; panel = nil
        for i in session.tabs.indices {
            if let url = session.tabs[i].url, !AddressResolver.isWebURL(url) {
                session.tabs[i].url = nil; session.tabs[i].title = "New tab"
            }
        }
        address = selectedTab.url?.absoluteString ?? ""
        if isPrivate { privateDataStore = .nonPersistent() }
    }
    func resetAfterProfileDeletion(replacementID: UUID) {
        guard !isClosed, let replacement = app.library.profiles.first(where: { $0.id == replacementID }) else { return }
        disposeEngineTabs(); closedTabs.removeAll(); panel = nil
        if isPrivate { ChromiumRuntime.shared.releasePrivateProfile(session.profileID, sessionID: session.id) }
        session = app.library.sessions.first(where: { $0.id == session.id }) ??
            WindowSession(id: session.id, profileID: replacementID, tabs: [BrowserTab(engineID: replacement.engineID ?? .chromium)])
        address = ""; addressEditing = false
        if isPrivate { privateDataStore = .nonPersistent() }
    }
    private func safeReopeningURL(_ descriptor: BrowserTab) -> URL? {
        if descriptor.engineID == .chromium, let selected = descriptor.chromiumPages?.first {
            return selected.url.flatMap { AddressResolver.isWebURL($0) ? $0 : nil }
        }
        return descriptor.url.flatMap { AddressResolver.isWebURL($0) ? $0 : nil }
    }
    func reopenTab(_ id: UUID, with engine: BrowserEngineID) {
        guard !isClosed, !app.finalQuitDataFrozen else { return }
        guard !app.deletingProfileIDs.contains(session.profileID) else { app.notice = "Wait for profile deletion to finish before switching engines."; return }
        let profileID = session.profileID
        webTabs[id]?.refreshActiveContent()
        captureChromiumSessions()
        if let chromium = webTabs[id] as? ChromiumTab, !chromium.isReadyForEngineSwitch {
            app.notice = "Wait for this Chrome pane to finish restoring its tabs and active page before switching engines."
            return
        }
        guard let descriptor = session.tabs.first(where: { $0.id == id }), descriptor.engineID != engine else { return }
        if descriptor.engineID != .chromium, let url = descriptor.url, !AddressResolver.isWebURL(url) {
            app.notice = "Generated pages cannot be reopened in another engine. Open the original website instead."; return
        }
        if engine == .chromium && !ChromiumRuntime.shared.isInstalled(in: app.dataDirectory) {
            app.notice = "Install Chromium in Settings → Browsing engines → Installation and updates, then reopen this tab."; return
        }
        let safeURL = safeReopeningURL(descriptor)
        let hasOtherChromeTabs = (descriptor.chromiumPages?.count ?? 0) > 1
        let hasGeneratedChromePage = descriptor.engineID == .chromium && descriptor.url.map {
            !AddressResolver.isWebURL($0) && !["about:blank", "chrome://newtab/", "chrome://new-tab-page/"].contains($0.absoluteString)
        } == true
        if safeURL != nil || hasOtherChromeTabs || hasGeneratedChromePage {
            let reviewedPage = webTabs[id]
            let reviewedRevision = reviewedPage?.navigationRevision
            let alert = NSAlert()
            alert.messageText = safeURL == nil ? "Switch this pane to \(engine.label)?" : "Reopen this page in \(engine.label)?"
            alert.informativeText = hasOtherChromeTabs
                ? "Only the active Chrome tab reopens in the other engine. Other Chrome tabs, sign-ins, forms and unsaved work do not transfer."
                : "The page loads normally in a separate website context. Sign-ins, forms, and unsaved page work do not transfer."
            if safeURL == nil {
                alert.informativeText = "The new engine opens a blank page. The Chrome tabs in this pane and their unsaved work will close."
            }
            alert.addButton(withTitle: safeURL == nil ? "Switch engine" : "Reopen page"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            // Chromium continues processing callbacks during the native modal.
            // Apply only to the profile and pages whose loss was just reviewed.
            webTabs[id]?.refreshActiveContent()
            captureChromiumSessions()
            if let chromium = webTabs[id] as? ChromiumTab, !chromium.isReadyForEngineSwitch {
                app.notice = "The active Chrome page is not ready. Review the pane and try switching engines again."
                return
            }
            guard session.profileID == profileID, !app.deletingProfileIDs.contains(profileID),
                  let current = session.tabs.first(where: { $0.id == id }),
                  current.engineID == descriptor.engineID, safeReopeningURL(current) == safeURL,
                  current.url == descriptor.url, current.chromiumPages == descriptor.chromiumPages,
                  webTabs[id] === reviewedPage, webTabs[id]?.navigationRevision == reviewedRevision else {
                app.notice = "The tabs changed while confirmation was open. Review the pane and try again."
                return
            }
        }
        changeEngine(id, to: engine)
    }
    func changeEngine(_ id: UUID, to engine: BrowserEngineID) {
        guard !isClosed, !app.finalQuitDataFrozen, !app.deletingProfileIDs.contains(session.profileID),
              app.library.profiles.contains(where: { $0.id == session.profileID }),
              let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        if session.tabs[index].engineID != .chromium, let url = session.tabs[index].url, !AddressResolver.isWebURL(url) { return }
        moveLiveTabHere(id)
        let url = safeReopeningURL(session.tabs[index])
        webTabs.removeValue(forKey: id)?.dispose()
        session.tabs[index].engineID = engine
        session.tabs[index].chromiumPages = nil
        session.tabs[index].url = url
        if url == nil { session.tabs[index].title = "New tab" }
        if session.selectedTabID == id { address = url?.absoluteString ?? ""; addressEditing = false }
        _ = webTab(id)
    }
    func toggleBookmark() {
        guard !isPrivate else { return }
        let page = activeWebTab
        page.refreshActiveContent()
        guard let url = page.url, AddressResolver.isWebURL(url) else { return }
        app.toggleBookmark(url: url, title: boundedPageTitle(page.title ?? url.host ?? "Website"), profileID: session.profileID)
    }
    func togglePanel(_ next: BrowserPanel) {
        if panel == next { panel = nil }
        else {
            if configuration.layout.sidebar == .hidden {
                var configuration = self.configuration; configuration.layout.sidebar = .leading
                app.applyConfiguration(configuration, to: session.spaceID)
            }
            panel = next
        }
    }
    func closeWindow() {
        guard !isClosed else { return }
        if !isPrivate {
            for id in Array(webTabs.keys) {
                if let next = app.windows.values.compactMap(\.model).first(where: { $0 !== self && !$0.isClosed && $0.session.tabs.contains(where: { $0.id == id }) }) { next.moveLiveTabHere(id) }
            }
        }
        isClosed = true
        disposeEngineTabs()
        if isPrivate { ChromiumRuntime.shared.closePrivateSession(session.id) }
        if isPrivate { downloads.cancelAll() }
        if !isPrivate { app.closeSession(session.id) }
        privateDataStore = nil; closedTabs.removeAll(); app.unregisterWindow(session.id)
    }
    func disposeEngineTabs() {
        for id in webTabs.keys { app.tabOwnership.release(id, from: session.id) }
        webTabs.values.forEach { $0.dispose() }; webTabs.removeAll(); tabProfiles.removeAll()
    }
    func disposeEngineTabs(profileID: UUID) {
        closedTabStacks = closedTabStacks.filter { $0.key.profileID != profileID }
        for id in Array(webTabs.keys) where tabProfiles[id] == profileID {
            app.tabOwnership.release(id, from: session.id)
            webTabs.removeValue(forKey: id)?.dispose(); tabProfiles.removeValue(forKey: id)
        }
    }
    func disposeEngineTabs(engine: BrowserEngineID) {
        for id in Array(webTabs.keys) where webTabs[id]?.engineID == engine {
            app.tabOwnership.release(id, from: session.id)
            webTabs.removeValue(forKey: id)?.dispose(); tabProfiles.removeValue(forKey: id)
        }
    }
    func takeLiveTab(_ id: UUID) -> BrowserEngineTab? {
        let tab = webTabs.removeValue(forKey: id)
        tabProfiles.removeValue(forKey: id)
        objectWillChange.send(); return tab
    }
    func moveLiveTabHere(_ id: UUID) {
        guard !isPrivate, !app.finalQuitDataFrozen else { return }
        if let owner = app.tabOwnership.owner(of: id), owner != session.id,
           let tab = app.windows[owner]?.model?.takeLiveTab(id) {
            attach(tab, id: id)
        }
        movedTabPlaceholders.removeValue(forKey: id)
    }
    func receiveSharedTabs(_ tabs: [BrowserTab]) {
        guard !isClosed, !app.finalQuitDataFrozen else { return }
        let previousSelection = session.selectedTabID
        receivingSharedTabs = true
        session.tabs = tabs; session.normalize()
        receivingSharedTabs = false
        if previousSelection != session.selectedTabID || !addressEditing { address = selectedTab.url?.absoluteString ?? "" }
    }
    func switchSpace(_ id: UUID) {
        guard !isPrivate, !isClosed, !app.finalQuitDataFrozen,
              let space = app.library.spaces?.first(where: { $0.id == id }),
              !app.deletingProfileIDs.contains(space.profileID) else { return }
        captureChromiumSessions()
        if let currentSpaceID = session.spaceID { spacePresentations[currentSpaceID] = session }
        var next = spacePresentations[id] ?? WindowSession(id: session.id, profileID: space.profileID, tabs: space.tabs)
        next.tabs = space.tabs; next.profileID = space.profileID; next.normalize()
        next.spaceID = id; session = next
        panel = nil; addressEditing = false; address = selectedTab.url?.absoluteString ?? ""
        moveLiveTabHere(session.selectedTabID)
        synchronizeSplit()
    }
    func moveTab(_ id: UUID, toSpace destination: UUID) {
        guard !isPrivate, !isClosed, !app.finalQuitDataFrozen,
              let source = session.spaceID, source != destination,
              let from = app.library.spaces?.firstIndex(where: { $0.id == source }),
              let to = app.library.spaces?.firstIndex(where: { $0.id == destination && $0.profileID == session.profileID }),
              (app.library.spaces?[to].tabs.count ?? 200) < 200,
              let descriptor = session.tabs.first(where: { $0.id == id }) else { return }
        moveLiveTabHere(id)
        captureChromiumSessions()
        let live = takeLiveTab(id)
        var moved = session.tabs.first(where: { $0.id == id }) ?? descriptor
        moved.parentID = nil; moved.folderID = nil; moved.collapsed = nil
        // Move in one library transaction: normalization never sees duplicate IDs.
        var library = app.library
        library.spaces?[from].tabs.removeAll { $0.id == id }
        for i in library.spaces![from].tabs.indices where library.spaces![from].tabs[i].parentID == id {
            library.spaces![from].tabs[i].parentID = descriptor.parentID
        }
        if library.spaces![from].tabs.isEmpty { library.spaces![from].tabs = [BrowserTab(engineID: profile.engineID ?? .chromium)] }
        library.spaces?[to].tabs.append(moved)
        if let tabs = library.spaces?[from].tabs { receiveSharedTabs(tabs) }
        app.library = library
        for window in app.windows.values.compactMap(\.model) where window !== self {
            if window.session.spaceID == source { window.receiveSharedTabs(library.spaces![from].tabs) }
            if window.session.spaceID == destination { window.receiveSharedTabs(library.spaces![to].tabs) }
        }
        switchSpace(destination)
        if let live { attach(live, id: id) }
        selectTab(id)
    }
    func captureChromiumSessions() {
        guard !isClosed, !app.finalQuitDataFrozen, !app.deletingProfileIDs.contains(session.profileID) else { return }
        for (id, tab) in webTabs {
            tab.refreshActiveContent()
            guard let pages = tab.chromiumSessionPages else { continue }
            guard let index = session.tabs.firstIndex(where: { $0.id == id }) else {
                if let profileID = tabProfiles[id], let space = app.library.spaces?.first(where: { $0.tabs.contains(where: { $0.id == id }) }) {
                    app.recordBackgroundTab(tab, id: id, spaceID: space.id, profileID: profileID, finished: false)
                }
                continue
            }
            let saved: [ChromiumSessionPage]? = tab.isShowingStartPage && pages.count == 1 ? nil : ChromiumSessionPage.normalized(pages)
            if session.tabs[index].chromiumPages != saved { session.tabs[index].chromiumPages = saved }
        }
    }
    func resynchronizeCachedPages() {
        // Engine commits can arrive while the final snapshot is frozen. Replay
        // the existing adapters on refusal without recreating live documents.
        for tab in webTabs.values { tab.onChange?(false) }
    }
}
enum BrowserPanel: String, CaseIterable, Identifiable {
    case bookmarks, history, downloads, notes, resources
    var id: Self { self }
    var label: String { switch self { case .resources: "Resources"; default: rawValue.capitalized } }
    var icon: String {
        switch self { case .bookmarks: "bookmark"; case .history: "clock"; case .downloads: "arrow.down.circle"; case .notes: "note.text"; case .resources: "gauge.with.dots.needle.33percent" }
    }
}
enum BrowserSheet: String, Identifiable { case modules, customize, settings, engines, recovery, extensions, assistant; var id: Self { self } }
