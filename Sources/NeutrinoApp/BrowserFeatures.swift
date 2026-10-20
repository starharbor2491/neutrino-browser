// SPDX-License-Identifier: MPL-2.0
import AppKit
import IOKit.ps
import MediaPlayer
import NeutrinoCore
import UniformTypeIdentifiers
@preconcurrency import WebKit

/// Native side of the shared browser features: page tools, per-site settings,
/// library collections, media, sleeping tabs and performance limits. The Rust
/// interface validates each request before it arrives here.
@MainActor
final class BrowserFeatures {
    private let app: AppState
    private weak var model: BrowserModel?
    private let window: () -> NSWindow?
    private let refresh: () -> Void
    private(set) var findResult: [String: Any] = [:]
    private(set) var navigationList: [String: Any] = [:]
    private(set) var source: [String: Any] = [:]
    private(set) var siteData: [[String: String]]?
    /// Card summaries for the interface, read from Keychain when they change.
    private var cards: (profileID: UUID, list: [[String: String]])?
    /// The tab whose page showed a payment form, to offer a saved card above it.
    private var cardOffer: UUID?
    /// Small pictures of tabs' pages for hover previews, taken while each tab was showing.
    private var thumbnails: [UUID: NSImage] = [:]
    /// The same pictures as small JPEG data addresses, for tab thumbnails in the tab bar.
    private var thumbnailData: [UUID: String] = [:]
    /// The address each Chromium thumbnail shows; Chromium pages are pictured once per page.
    private var thumbnailURLs: [UUID: URL] = [:]
    private lazy var preview = TabPreviewPanel()
    /// A sign-in waiting for Save, Never or Not now. The password never reaches the interface.
    private var passwordPrompt: (profileID: UUID, credential: LocalCredential, update: Bool)?
    private(set) var tabResources: [[String: Any]] = []
    /// A capture open in the markup editor, as a PNG data address, with the page title for saving.
    private var markup: (image: String, title: String)?
    /// The feed each tab's page advertises, with the address it was found on.
    private var pageFeeds: [UUID: (page: URL, feed: String)] = [:]
    private(set) var audible = Set<UUID>()
    private(set) var media: (id: UUID, playing: Bool)?
    private(set) var breakMode = false
    private(set) var suggestionQuery = ""
    var historyQuery = ""
    var bookmarkQuery = ""
    /// The settings page showing tab resource use is open.
    var sampleResources = false
    /// A web panel to open once the interface knows about it.
    var pendingPanel: String?
    var credentialsChanged = false
    private var loop: Task<Void, Never>?
    private var cpu: [UUID: (seconds: Double, at: Date)] = [:]
    private var blockedSeen: [UUID: Int] = [:]
    /// Brave's Playlist: the tab playing it, the reading items in order, and the one playing.
    private var playlist: (tab: UUID, items: [UUID], position: Int, since: Date)?
    private var firstSeen: [UUID: Date] = [:]
    private var overLimit = 0
    /// Background Chromium pages slowed by the CPU limit.
    private var throttled = Set<UUID>()
    private var breakMuted = Set<UUID>()
    private var wallpaper: (path: String, modified: Date, value: String)?
    private static var openedStartupPages = false

    init(app: AppState, model: BrowserModel?, window: @escaping () -> NSWindow?, refresh: @escaping () -> Void) {
        self.app = app; self.model = model; self.window = window; self.refresh = refresh
        DownloadCenter.defaultFolder = app.library.preferences.downloadFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    func start() {
        guard let model, loop == nil else { return }
        openStartupPages(model)
        loop = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self, let model = self.model, !model.isClosed else { return }
                await self.sampleMedia(model, includeChromium: tick % 3 == 0)
                if !model.isPrivate { self.countBlocked(model) }
                if tick % 10 == 0 { self.sleepIdleTabs(model); await self.captureThumbnail(model) }
                if tick % 200 == 0 { self.archiveIdleTabs(model) }
                if tick % 600 == 0, self.app.feature("feeds"), !model.isPrivate { await self.app.refreshFeeds(force: false) }
                if self.sampleResources || self.limitsEnabled { await self.sampleUsage(model) }
                else if !self.throttled.isEmpty { self.releaseThrottles(model) }
                tick += 1
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil; NowPlaying.clear(self) }

    private func openStartupPages(_ model: BrowserModel) {
        let preferences = app.library.preferences
        guard !Self.openedStartupPages, !model.isPrivate, !preferences.restoreSession else { return }
        Self.openedStartupPages = true
        for page in (preferences.startupPages ?? []).prefix(20) {
            if let url = URL(string: page), AddressResolver.isWebURL(url) { model.newTab(url: url) }
        }
    }

    // MARK: Snapshot

    func snapshot(into snapshot: inout [String: Any], model: BrowserModel) {
        let live = Set(model.liveEngineTabs.map(\.id))
        snapshot["audible"] = audible.filter(live.contains).map(\.uuidString)
        snapshot["sleeping"] = model.sleepingTabIDs.map(\.uuidString)
        if let media, model.session.tabs.contains(where: { $0.id == media.id }) {
            snapshot["media"] = ["id": media.id.uuidString, "playing": media.playing]
        }
        snapshot["closedTabs"] = model.closedTabs.reversed().prefix(10).map { ["title": String($0.title.prefix(200)), "url": $0.url?.absoluteString ?? ""] }
        snapshot["findResult"] = findResult
        snapshot["navigationList"] = navigationList
        snapshot["source"] = source
        if let siteData { snapshot["siteData"] = siteData }
        snapshot["tabResources"] = tabResources
        snapshot["breakMode"] = breakMode
        if let markup { snapshot["markupImage"] = markup.image }
        if let blocked = model.activeWebTab.blockedOnPage { snapshot["blockedCount"] = blocked }
        if let found = pageFeeds[model.session.selectedTabID], found.page == model.activeWebTab.url,
           !(app.library.preferences.feeds ?? []).contains(where: { $0.profileID == model.session.profileID && $0.url.absoluteString == found.feed }) {
            snapshot["pageFeed"] = found.feed
        }
        if !model.isPrivate {
            if cards?.profileID != model.session.profileID { cards = (model.session.profileID, LocalCard.list(profile: model.session.profileID).map(\.summary)) }
            snapshot["cards"] = cards?.list ?? []
            if cardOffer == model.session.selectedTabID { snapshot["cardOffer"] = true }
        }
        if let prompt = passwordPrompt, prompt.profileID == model.session.profileID {
            snapshot["passwordPrompt"] = ["origin": prompt.credential.origin, "username": prompt.credential.username, "update": prompt.update]
        }
        if let queue = playlist, !model.isPrivate, let item = app.library.preferences.readingList?.first(where: { $0.id == queue.items[queue.position] }) {
            snapshot["playlist"] = ["position": queue.position + 1, "count": queue.items.count, "title": item.title]
        }
        if model.configuration.layout.tabThumbnails == true, !model.isPrivate {
            snapshot["tabThumbnails"] = Dictionary(uniqueKeysWithValues: thumbnailData.prefix(60).map { ($0.key.uuidString, $0.value) })
        }
        if throttled.remove(model.session.selectedTabID) != nil { model.liveEngineTab(model.session.selectedTabID)?.setProcessorThrottle(1) }
        let counted = model.liveEngineTabs.compactMap { $0.page.blockedTotal }
        let lifetime = model.isPrivate ? 0 : app.library.preferences.blockedLifetime ?? 0
        if !counted.isEmpty || lifetime > 0 { snapshot["shieldsStats"] = ["blocked": counted.reduce(0, +), "lifetime": lifetime] }
        snapshot["onBattery"] = Self.onBattery
        snapshot["now"] = Date().timeIntervalSinceReferenceDate
        snapshot["historyQuery"] = historyQuery
        snapshot["bookmarkQuery"] = bookmarkQuery
        snapshot["suggestions"] = suggestions(profileID: model.session.profileID, regular: !model.isPrivate)
        snapshot["wallpaper"] = wallpaperValue(model.session.profileID)
    }
    /// Bookmarks and history that match what the person is typing, best first.
    private func suggestions(profileID: UUID, regular: Bool) -> [[String: String]] {
        let query = suggestionQuery.lowercased()
        guard regular, !query.isEmpty else { return [] }
        func matches(_ title: String, _ url: URL) -> Bool { title.lowercased().contains(query) || url.absoluteString.lowercased().contains(query) }
        var out: [[String: String]] = []
        var seen = Set<String>()
        for bookmark in app.library.bookmarks where bookmark.profileID == profileID && matches(bookmark.title, bookmark.url) {
            if seen.insert(bookmark.url.absoluteString).inserted { out.append(["kind": "bookmark", "title": bookmark.title, "url": bookmark.url.absoluteString]) }
            if out.count == 3 { break }
        }
        var visits: [String: (title: String, count: Int, last: Date)] = [:]
        for entry in app.library.history.suffix(5000) where entry.profileID == profileID && matches(entry.title, entry.url) {
            let key = entry.url.absoluteString
            let current = visits[key]
            visits[key] = (entry.title, (current?.count ?? 0) + 1, max(current?.last ?? .distantPast, entry.visitedAt))
        }
        let ranked = visits.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.value.last > $1.value.last }
        for (url, visit) in ranked where seen.insert(url).inserted {
            out.append(["kind": "history", "title": visit.title, "url": url])
            if out.count == 7 { break }
        }
        return out
    }
    private func wallpaperValue(_ profileID: UUID) -> String {
        let file = app.dataDirectory.appendingPathComponent("wallpaper-\(profileID.uuidString).jpg")
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return "" }
        if let wallpaper, wallpaper.path == file.path, wallpaper.modified == modified { return wallpaper.value }
        guard let data = try? Data(contentsOf: file), data.count <= 2_800_000 else { return "" }
        let value = "data:image/jpeg;base64," + data.base64EncodedString()
        wallpaper = (file.path, modified, value)
        return value
    }

    // MARK: Sampling

    /// WebKit tabs are checked every pass. Chromium tabs answer through DevTools, so
    /// only the selected tab and the one already playing are checked, less often.
    private func sampleMedia(_ model: BrowserModel, includeChromium: Bool) async {
        guard let script = PageScript.source("mediaState") else { return }
        var playing = audible.filter { id in model.liveEngineTab(id)?.engineID == .chromium && !includeChromium }
        var current = media
        for (id, page) in model.liveEngineTabs.prefix(40) where page.url != nil && !page.loading {
            if page.engineID == .chromium && (!includeChromium || (id != model.session.selectedTabID && id != media?.id && !audible.contains(id))) { continue }
            guard let raw = try? await page.runPageScript(script), let data = raw.data(using: .utf8),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if state["audible"] as? Bool == true { playing.insert(id) }
            // The page just left can still report its ended video for a moment.
            if let queue = playlist, queue.tab == id, state["ended"] as? Bool == true, Date().timeIntervalSince(queue.since) > 8 { advancePlaylist(model) }
            if state["playing"] as? Bool == true { current = (id, true) }
            else if current?.id == id { current = state["media"] as? Bool == true ? (id, false) : nil }
        }
        if let id = current?.id, !model.session.tabs.contains(where: { $0.id == id }) { current = nil }
        if playing != audible || current?.id != media?.id || current?.playing != media?.playing {
            audible = playing; media = current; refresh()
        }
        publishNowPlaying(model)
    }
    /// The playing page appears in Now Playing and answers the media keys, in either
    /// engine: the Chromium bridge turns off Chrome's own media-key handling.
    private func publishNowPlaying(_ model: BrowserModel) {
        guard app.feature("media-controls"), !model.isPrivate, let media, model.liveEngineTab(media.id) != nil,
              let tab = model.session.tabs.first(where: { $0.id == media.id }) else { NowPlaying.clear(self); return }
        NowPlaying.show(self, title: tab.customTitle ?? tab.title, site: tab.url?.host ?? "", playing: media.playing)
    }
    /// Marks the playing Playlist item read and opens the next one in the same tab.
    private func advancePlaylist(_ model: BrowserModel) {
        guard var queue = playlist, var list = app.library.preferences.readingList else { playlist = nil; return }
        if let index = list.firstIndex(where: { $0.id == queue.items[queue.position] }) { list[index].read = true }
        app.library.preferences.readingList = list
        queue.position += 1; queue.since = Date()
        guard queue.position < queue.items.count, let next = list.first(where: { $0.id == queue.items[queue.position] }),
              model.session.tabs.contains(where: { $0.id == queue.tab }) else {
            playlist = nil; app.notice = "Playlist finished."; refresh(); return
        }
        playlist = queue
        if model.session.selectedTabID != queue.tab { model.selectTab(queue.tab) }
        model.liveEngineTab(queue.tab)?.load(next.url)
        refresh()
    }
    /// Brave's start page counts every tracker and ad blocked, not only those in open tabs.
    private func countBlocked(_ model: BrowserModel) {
        var added = 0
        for (id, page) in model.liveEngineTabs {
            guard let total = page.blockedTotal else { continue }
            // A page that was closed and reopened starts counting again from zero.
            let previous = blockedSeen[id] ?? 0
            added += total >= previous ? total - previous : total
            blockedSeen[id] = total
        }
        if added > 0 { app.library.preferences.blockedLifetime = min(Int.max / 2, (app.library.preferences.blockedLifetime ?? 0) + added) }
    }
    /// After a page loads: offers saved cards when it shows a payment form.
    func checkCardForm(_ tab: BrowserEngineTab, id: UUID, profileID: UUID) {
        if cardOffer == id { cardOffer = nil; refresh() }
        if cards?.profileID != profileID { cards = (profileID, LocalCard.list(profile: profileID).map(\.summary)) }
        guard !(cards?.list.isEmpty ?? true), let url = tab.url, url.scheme == "https", let script = PageScript.source("cardForm") else { return }
        Task { @MainActor [weak self] in
            guard (try? await tab.runPageScript(script)) == "1", tab.url == url, let self else { return }
            self.cardOffer = id; self.refresh()
        }
    }
    /// A media key: toggles the page that is playing or was last paused.
    fileprivate func mediaKey(play: Bool?) {
        guard let media, play == nil || play != media.playing else { return }
        _ = perform("mediaToggle", ["id": media.id.uuidString])
    }
    private var limitsEnabled: Bool {
        app.feature("limiter") && ((app.library.preferences.memoryLimitMB ?? 0) > 0 || (app.library.preferences.cpuLimit ?? 0) > 0)
    }
    private func sampleUsage(_ model: BrowserModel) async {
        var rows: [[String: Any]] = []
        var memory = 0.0, processor = 0.0
        let now = Date()
        for (id, page) in model.liveEngineTabs.prefix(60) {
            guard let usage = await page.resourceUsage(), let tab = model.session.tabs.first(where: { $0.id == id }) else { continue }
            var percent = 0.0
            if let previous = cpu[id], now.timeIntervalSince(previous.at) > 0.5 {
                percent = max(0, (usage.cpuSeconds - previous.seconds) / now.timeIntervalSince(previous.at) * 100)
            }
            cpu[id] = (usage.cpuSeconds, now)
            memory += usage.memoryMB; processor += percent
            rows.append(["id": id.uuidString, "title": tab.customTitle ?? tab.title, "memory": usage.memoryMB, "cpu": percent])
        }
        rows.sort { ($0["memory"] as? Double ?? 0) > ($1["memory"] as? Double ?? 0) }
        tabResources = rows
        enforceLimits(model, memory: memory, processor: processor)
        if sampleResources { refresh() }
    }
    /// A page loaded in this session counts as used when it loaded, whatever its saved date.
    private func lastUsed(_ id: UUID, _ model: BrowserModel) -> Date {
        max(model.session.tabs.first(where: { $0.id == id })?.lastUsedAt ?? .distantPast, firstSeen[id] ?? Date())
    }
    /// Above a memory or processor limit for two samples in a row, the least
    /// recently used background tab goes to sleep.
    private func enforceLimits(_ model: BrowserModel, memory: Double, processor: Double) {
        let preferences = app.library.preferences
        guard app.feature("limiter") else { overLimit = 0; releaseThrottles(model); return }
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        let memoryLimit = Double(preferences.memoryLimitMB ?? 0), processorLimit = Double(preferences.cpuLimit ?? 0)
        let share = processor / cores
        let candidates = model.liveEngineTabs.map(\.id).filter { $0 != model.session.selectedTabID && !audible.contains($0) && model.session.split?.contains($0) != true }
        // CPU limit: background Chromium pages first run at a quarter of their speed, and
        // return to full speed once usage is well below the limit.
        if processorLimit > 0 && share > processorLimit {
            for (id, page) in model.liveEngineTabs where page.engineID == .chromium && candidates.contains(id) && !throttled.contains(id) {
                page.setProcessorThrottle(4); throttled.insert(id)
            }
        } else if processorLimit == 0 || share < processorLimit * 0.6 {
            releaseThrottles(model)
        }
        let over = (memoryLimit > 0 && memory > memoryLimit) || (processorLimit > 0 && share > processorLimit)
        overLimit = over ? overLimit + 1 : 0
        // Still over after slowing pages down: the least recently used background tab sleeps.
        guard overLimit >= 3 else { return }
        if let oldest = candidates.min(by: { lastUsed($0, model) < lastUsed($1, model) }) { model.sleepTab(oldest); throttled.remove(oldest); overLimit = 0 }
    }
    private func releaseThrottles(_ model: BrowserModel) {
        for id in throttled { model.liveEngineTab(id)?.setProcessorThrottle(1) }
        throttled.removeAll()
    }
    private func sleepIdleTabs(_ model: BrowserModel) {
        let preferences = app.library.preferences
        var minutes = preferences.sleepAfterMinutes ?? 60
        if preferences.batterySaver == true, Self.onBattery { minutes = minutes == 0 ? 5 : min(minutes, 5) }
        let now = Date()
        for id in model.liveEngineTabs.map(\.id) where firstSeen[id] == nil { firstSeen[id] = now }
        guard minutes > 0, app.feature("tab-sleep") else { return }
        let cutoff = now.addingTimeInterval(-Double(minutes) * 60)
        for id in model.liveEngineTabs.map(\.id) where !audible.contains(id) && lastUsed(id, model) < cutoff {
            model.sleepTab(id)
            if model.liveEngineTab(id) == nil { firstSeen.removeValue(forKey: id) }
        }
    }
    /// Pictures the selected tab while it is showing, for its hover preview later.
    private func captureThumbnail(_ model: BrowserModel) async {
        guard app.feature("tab-previews") || model.configuration.layout.tabThumbnails == true else { thumbnails.removeAll(); thumbnailData.removeAll(); return }
        let id = model.session.selectedTabID
        guard let page = model.liveEngineTab(id), let url = page.url, !page.loading, page.nativeView.window != nil,
              page.engineID == .webkit || thumbnailURLs[id] != url,
              let png = try? await page.capturePNG(), let image = NSImage(data: png) else { return }
        thumbnailURLs[id] = url
        let width: CGFloat = 320, scale = width / max(1, image.size.width)
        let small = NSImage(size: NSSize(width: width, height: min(240, image.size.height * scale)))
        small.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: NSSize(width: width, height: image.size.height * scale)).offsetBy(dx: 0, dy: small.size.height - image.size.height * scale))
        small.unlockFocus()
        thumbnails[id] = small
        if model.configuration.layout.tabThumbnails == true, let tiff = small.tiffRepresentation,
           let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.6]), jpeg.count <= 40_000 {
            thumbnailData[id] = "data:image/jpeg;base64," + jpeg.base64EncodedString(); refresh()
        }
        let open = Set(model.session.tabs.map(\.id))
        thumbnails = thumbnails.filter { open.contains($0.key) }
        thumbnailData = thumbnailData.filter { open.contains($0.key) }
        thumbnailURLs = thumbnailURLs.filter { open.contains($0.key) }
    }
    /// Arc archives tabs left unused for the chosen number of days, as it does at launch.
    private func archiveIdleTabs(_ model: BrowserModel) {
        guard let days = app.library.preferences.autoArchiveDays, days > 0, !model.isPrivate,
              let spaceID = model.session.spaceID, let index = app.library.spaces?.firstIndex(where: { $0.id == spaceID }) else { return }
        let cutoff = Date().addingTimeInterval(-Double(min(days, 365)) * 86400)
        let idle = model.session.tabs.filter { tab in
            !tab.pinned && tab.folderID == nil && tab.url != nil && tab.id != model.session.selectedTabID
                && model.session.split?.contains(tab.id) != true && !audible.contains(tab.id)
                && model.liveEngineTab(tab.id)?.hasActiveDownloads != true && lastUsed(tab.id, model) < cutoff
        }
        for tab in idle.prefix(20) {
            app.library.spaces?[index].archivedTabs.insert(tab, at: 0)
            model.closeTab(tab.id)
        }
        if let count = app.library.spaces?[index].archivedTabs.count, count > 500 { app.library.spaces?[index].archivedTabs.removeLast(count - 500) }
    }
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == "Battery Power"
    }

    func foundFeed(_ feed: String, page: URL, tab id: UUID) {
        let previous = pageFeeds[id]?.feed
        if feed.isEmpty { pageFeeds.removeValue(forKey: id) } else { pageFeeds[id] = (page, String(feed.prefix(2048))) }
        if let open = model?.session.tabs.map(\.id) { pageFeeds = pageFeeds.filter { open.contains($0.key) } }
        if previous != pageFeeds[id]?.feed { refresh() }
    }

    // MARK: Commands

    /// Performs a feature command; false when the operation is not one of these.
    func perform(_ operation: String, _ command: [String: Any]) -> Bool {
        let id = (command["id"] as? String).flatMap(UUID.init(uuidString:))
        let profileID = model?.session.profileID ?? app.library.profiles[0].id
        let regular = model?.isPrivate != true
        switch operation {
        case "muteTab":
            guard let model, let id, let index = model.session.tabs.firstIndex(where: { $0.id == id }) else { break }
            let muted = command["value"] as? Bool ?? true
            model.session.tabs[index].muted = muted ? true : nil
            model.liveEngineTab(id)?.setMuted(muted)
        case "copyText":
            if let value = command["value"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
        case "sleepTab": if let id { model?.sleepTab(id) }
        case "newTabAfter": if let id { model?.newTab(after: id) }
        case "closeTabs": model?.closeTabs((command["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
        case "resetPinnedTab":
            guard let model, let id, let url = model.session.tabs.first(where: { $0.id == id })?.pinnedURL else { break }
            model.selectTab(id); model.navigate(url.absoluteString)
        case "addFavorite":
            guard regular, let model, let id, let index = model.session.tabs.firstIndex(where: { $0.id == id }), let url = model.session.tabs[index].url else { break }
            var favorites = app.library.preferences.favorites ?? []
            guard favorites.filter({ $0.profileID == profileID }).count < 24 else { app.notice = "Favorites hold up to 24 sites."; break }
            let favorite = FavoriteSite(profileID: profileID, title: model.session.tabs[index].title, url: url)
            favorites.append(favorite)
            app.library.preferences.favorites = favorites
            model.session.tabs[index].favoriteID = favorite.id
        case "removeFavorite":
            guard let id else { break }
            app.library.preferences.favorites?.removeAll { $0.id == id }
            if let model { for i in model.session.tabs.indices where model.session.tabs[i].favoriteID == id { model.session.tabs[i].favoriteID = nil } }
        case "openFavorite":
            guard let model, let id, let favorite = app.library.preferences.favorites?.first(where: { $0.id == id && $0.profileID == profileID }) else { break }
            if let tab = model.session.tabs.first(where: { $0.favoriteID == id }) { model.selectTab(tab.id) }
            else {
                model.newTab(url: favorite.url)
                if let index = model.session.tabs.firstIndex(where: { $0.id == model.session.selectedTabID }) { model.session.tabs[index].favoriteID = id }
            }
        case "renameTab":
            guard let model, let id, let index = model.session.tabs.firstIndex(where: { $0.id == id }) else { break }
            let name = (command["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            model.session.tabs[index].customTitle = name.isEmpty ? nil : String(name.prefix(120))
        case "reopenClosed": model?.reopenClosedTab(at: command["index"] as? Int ?? 0)
        case "findCount":
            let query = command["value"] as? String ?? ""
            guard let model, !query.isEmpty, let script = PageScript.source("findCount", ["query": query]) else { findResult = ["query": query, "count": 0]; break }
            let tab = model.activeWebTab
            Task { @MainActor [weak self] in
                let count = Int((try? await tab.runPageScript(script)) ?? "") ?? 0
                self?.findResult = ["query": query, "count": count]; self?.refresh()
            }
        case "suggest": suggestionQuery = String((command["value"] as? String ?? "").prefix(2048))
        case "print": model?.activeWebTab.printPage()
        case "savePDF", "savePage":
            guard let model else { break }
            let tab = model.activeWebTab, title = model.selectedTab.title
            Task { @MainActor [weak self] in
                do {
                    let file = operation == "savePDF" ? (data: try await tab.pagePDF(), type: "pdf") : try await tab.pageArchive()
                    self?.save(file.data, name: title, type: file.type)
                } catch { self?.app.notice = error.localizedDescription }
            }
        case "viewSource":
            guard let model else { break }
            let tab = model.activeWebTab, url = model.selectedTab.url?.absoluteString ?? ""
            source = ["url": url, "text": ""]
            Task { @MainActor [weak self] in
                do { self?.source = ["url": url, "text": try await tab.pageHTML()] }
                catch { self?.source = ["url": url, "text": "The page source could not be read. " + error.localizedDescription] }
                self?.refresh()
            }
        case "devTools": model?.activeWebTab.showDeveloperTools()
        case "scrollTop", "scrollBottom":
            guard let model else { break }
            let tab = model.activeWebTab
            let target = operation == "scrollTop" ? "0" : "document.documentElement.scrollHeight"
            Task { _ = try? await tab.runPageScript("scrollTo({top:\(target),behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth'});'ok'") }
        case "fastForward":
            guard let model, let script = PageScript.source("nextPage") else { break }
            let tab = model.activeWebTab
            Task { @MainActor [weak self] in
                if let next = try? await tab.runPageScript(script), let url = URL(string: next), AddressResolver.isWebURL(url) { tab.load(url) }
                else { self?.app.notice = "This page doesn’t link to a next page." }
            }
        case "rewind":
            guard let model else { break }
            let tab = model.activeWebTab, site = ContentBlocking.site(tab.url)
            Task { @MainActor [weak self] in
                // Go back to the first page of this visit to the site.
                let entries = await tab.navigationEntries(back: true)
                let run = entries.prefix { ContentBlocking.site(URL(string: $0["url"] as? String ?? "")) == site }
                if let offset = run.last?["offset"] as? Int { tab.goToHistory(offset: offset) }
                else { self?.app.notice = "This is the first page of the site in this tab." }
            }
        case "pickElement":
            guard regular, let model, let site = ContentBlocking.site(model.activeWebTab.url) else { break }
            let label = model.configuration.theme.preset == "arc" ? "Click an element to zap it. Press Esc to cancel." : "Click an element to hide it on this site. Press Esc to cancel."
            guard let script = PageScript.source("pick", ["label": label]) else { break }
            let tab = model.activeWebTab
            tab.focus()
            Task { @MainActor [weak self] in
                guard let selector = try? await tab.runPageScript(script, wait: .seconds(110)), !selector.isEmpty, selector.count <= 200, let self else { return }
                var all = self.app.library.preferences.siteSettings ?? [:], settings = all[site] ?? SiteSettings()
                settings.hide = Array(((settings.hide ?? []).filter { $0 != selector } + [selector]).suffix(50))
                all[site] = settings
                self.app.library.preferences.siteSettings = all
                self.applySite(site, reloadWebKit: false)
                self.app.notice = "Hidden on \(site). Show it again from the site menu."
            }
        case "share":
            guard let model, let url = model.selectedTab.url, let view = window()?.contentView else { break }
            NSSharingServicePicker(items: [url]).show(relativeTo: NSRect(x: view.bounds.maxX - 140, y: view.bounds.maxY - 56, width: 1, height: 1), of: view, preferredEdge: .minY)
        case "pip", "mediaToggle":
            guard let model, let script = PageScript.source(operation == "pip" ? "pip" : "mediaToggle") else { break }
            let target = id.flatMap { model.liveEngineTab($0) } ?? model.activeWebTab
            let tabID = id ?? model.session.selectedTabID
            Task { @MainActor [weak self] in
                let result = (try? await target.runPageScript(script, userGesture: true)) ?? "none"
                guard let self else { return }
                if result == "none" { self.app.notice = operation == "pip" ? "This page has no video to show in picture in picture." : "This page has nothing to play." }
                if operation == "mediaToggle", result != "none" { self.media = (tabID, result == "playing"); self.refresh() }
            }
        case "breakMode":
            guard let model else { break }
            breakMode.toggle()
            if breakMode {
                breakMuted = Set(model.liveEngineTabs.map(\.id))
                let pause = PageScript.source("pauseAll")
                for (_, page) in model.liveEngineTabs {
                    if let pause { Task { _ = try? await page.runPageScript(pause) } }
                    page.setMuted(true)
                }
            } else {
                for (tabID, page) in model.liveEngineTabs where breakMuted.contains(tabID) {
                    page.setMuted(model.session.tabs.first(where: { $0.id == tabID })?.muted == true)
                }
                breakMuted = []
            }
        case "panic":
            if let model {
                for (tabID, page) in model.liveEngineTabs {
                    page.setMuted(true)
                    if let index = model.session.tabs.firstIndex(where: { $0.id == tabID }) { model.session.tabs[index].muted = true }
                }
            }
            NSApp.hide(nil)
        case "navigationList":
            guard let model else { break }
            let back = command["direction"] as? String != "forward", tab = model.activeWebTab
            navigationList = [:]
            Task { @MainActor [weak self] in
                let items = await tab.navigationEntries(back: back)
                self?.navigationList = ["direction": back ? "back" : "forward", "items": items]; self?.refresh()
            }
        case "goToHistory": if let offset = command["offset"] as? Int { model?.activeWebTab.goToHistory(offset: offset) }
        case "siteSetting", "siteBoost":
            guard regular, let host = command["host"] as? String, !host.isEmpty, host.count <= 253 else { break }
            var settings = app.library.preferences.siteSettings?[host] ?? SiteSettings()
            let key = command["key"] as? String
            if operation == "siteBoost" {
                let css = command["css"] as? String ?? ""
                settings.css = css.isEmpty ? nil : String(css.prefix(20_000))
                let hide = (command["hide"] as? [String] ?? []).prefix(50).map { String($0.prefix(200)) }
                settings.hide = hide.isEmpty ? nil : Array(hide)
                let js = command["js"] as? String ?? ""
                settings.js = js.isEmpty ? nil : String(js.prefix(20_000))
                settings.hue = (command["hue"] as? Int).flatMap { (1..<360).contains($0) ? $0 : nil }
            } else {
                let on = command["value"] as? Bool == true
                let choice = (command["value"] as? String).flatMap { ["", "ask"].contains($0) ? nil : $0 }
                switch key {
                case "blockScripts": settings.blockScripts = on ? true : nil
                case "allowPopups": settings.allowPopups = on ? true : nil
                case "muted": settings.muted = on ? true : nil
                case "camera": settings.camera = choice
                case "microphone": settings.microphone = choice
                case "filter": settings.filter = choice
                case "hide": settings.hide = nil
                case "forget": settings.forget = on ? true : nil
                default: return true
                }
            }
            var all = app.library.preferences.siteSettings ?? [:]
            all[host] = settings == SiteSettings() ? nil : settings
            app.library.preferences.siteSettings = all
            applySite(host, reloadWebKit: key == "blockScripts")
        case "siteReset":
            guard regular, let host = command["host"] as? String, !host.isEmpty else { break }
            app.library.preferences.siteSettings?.removeValue(forKey: host)
            app.library.preferences.siteZoom?.removeValue(forKey: host)
            applySite(host, reloadWebKit: true)
        case "clearBrowsingData":
            guard let model else { break }
            let since: Date = switch command["range"] as? String {
            case "hour": Date().addingTimeInterval(-3600)
            case "day": Date().addingTimeInterval(-86_400)
            case "week": Date().addingTimeInterval(-604_800)
            case "month": Date().addingTimeInterval(-2_419_200)
            default: .distantPast
            }
            let visitedHosts = Array(Set(app.library.history.filter { $0.profileID == profileID && $0.visitedAt >= since }.compactMap { $0.url.host?.lowercased() }))
            if command["history"] as? Bool == true { app.library.history.removeAll { $0.profileID == profileID && $0.visitedAt >= since } }
            if command["downloads"] as? Bool == true { model.downloads.removeFinished() }
            let cookies = command["cookies"] as? Bool == true, cache = command["cache"] as? Bool == true
            var types = Set<String>()
            if cookies { types.formUnion([WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases, WKWebsiteDataTypeServiceWorkerRegistrations]) }
            if cache { types.formUnion([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache]) }
            guard !types.isEmpty, regular else { break }
            app.webKitDataStore(profileID: profileID).removeData(ofTypes: types, modifiedSince: since) {}
            let chromium = model.liveEngineTabs.map(\.page).first { $0.engineID == .chromium }
            if let chromium { Task { await chromium.clearWebsiteData(cookies: cookies, cache: cache, hosts: visitedHosts, since: since) } }
            else if model.session.tabs.contains(where: { $0.engineID == .chromium && $0.url != nil }) {
                app.notice = "WebKit data was cleared. Open a Chromium tab, then clear again to include Chromium’s cookies and cache."
            }
        case "loadSiteData":
            guard regular, let model else { break }
            let chromium = model.liveEngineTabs.map(\.page).first { $0.engineID == .chromium }
            app.webKitDataStore(profileID: profileID).fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
                guard let self else { return }
                let found = records.prefix(500).map { ["host": $0.displayName, "detail": Self.describe($0.dataTypes)] }
                Task { @MainActor in
                    var rows = found
                    for domain in await chromium?.cookieDomains() ?? [] where !rows.contains(where: { $0["host"] == domain }) {
                        rows.append(["host": domain, "detail": "Cookies (Chromium)"])
                    }
                    self.siteData = rows.sorted { ($0["host"] ?? "") < ($1["host"] ?? "") }; self.refresh()
                }
            }
        case "clearSiteData":
            guard regular, let model, let host = command["host"] as? String, !host.isEmpty else { break }
            let store = app.webKitDataStore(profileID: profileID), all = WKWebsiteDataStore.allWebsiteDataTypes()
            store.fetchDataRecords(ofTypes: all) { [weak self] records in
                guard let self else { return }
                let matching = records.filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
                store.removeData(ofTypes: all, for: matching) {
                    Task { @MainActor in self.siteData?.removeAll { $0["host"] == host }; self.refresh() }
                }
            }
            for page in model.liveEngineTabs.map(\.page) where page.engineID == .chromium { Task { await page.clearSiteData(host: host) }; break }
            app.notice = "Data stored by \(host) was removed."
        case "historyQuery": historyQuery = String((command["value"] as? String ?? "").prefix(160))
        case "bookmarkQuery": bookmarkQuery = String((command["value"] as? String ?? "").prefix(160))
        case "removeHistory": if let id { app.library.history.removeAll { $0.id == id && $0.profileID == profileID } }
        case "editBookmark":
            guard regular, let id, let index = app.library.bookmarks.firstIndex(where: { $0.id == id && $0.profileID == profileID }),
                  let raw = command["url"] as? String, let url = URL(string: raw), AddressResolver.isWebURL(url) else { break }
            let folder = (command["folder"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            app.library.bookmarks[index].title = String((command["title"] as? String ?? url.host ?? "Website").prefix(512))
            app.library.bookmarks[index].url = url
            let path = folder.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "/")
            app.library.bookmarks[index].folder = path.isEmpty ? nil : String(path.prefix(160))
        case "moveBookmark":
            guard regular, let id, let from = app.library.bookmarks.firstIndex(where: { $0.id == id && $0.profileID == profileID }) else { break }
            var bookmark = app.library.bookmarks.remove(at: from)
            if let folder = command["folder"] as? String { bookmark.folder = folder.isEmpty ? nil : String(folder.prefix(160)) }
            let before = (command["before"] as? String).flatMap(UUID.init(uuidString:))
            if let before, let target = app.library.bookmarks.firstIndex(where: { $0.id == before }) {
                if command["folder"] == nil || command["folder"] is NSNull { bookmark.folder = app.library.bookmarks[target].folder }
                app.library.bookmarks.insert(bookmark, at: target)
            } else { app.library.bookmarks.append(bookmark) }
        case "addReadingItem":
            guard regular, let raw = command["url"] as? String, let url = URL(string: raw), AddressResolver.isWebURL(url) else { break }
            var list = app.library.preferences.readingList ?? []
            list.removeAll { $0.url == url && $0.profileID == profileID }
            list.insert(ReadingItem(profileID: profileID, title: String((command["title"] as? String ?? url.host ?? "Page").prefix(512)), url: url, media: command["media"] as? Bool == true), at: 0)
            app.library.preferences.readingList = Array(list.prefix(1000))
        case "playlist":
            guard regular, let model else { break }
            switch command["value"] as? String {
            case "start":
                let items = (app.library.preferences.readingList ?? []).filter { $0.profileID == profileID && $0.media == true && !$0.read }
                guard let first = items.first else { app.notice = "Your Playlist has nothing unread to play."; break }
                model.newTab(url: first.url)
                playlist = (model.session.selectedTabID, items.map(\.id), 0, Date())
            case "next": advancePlaylist(model)
            default: playlist = nil
            }
        case "readingItem":
            guard let id, var list = app.library.preferences.readingList, let index = list.firstIndex(where: { $0.id == id }) else { break }
            switch command["value"] as? String {
            case "remove": list.remove(at: index)
            case "read": list[index].read = true
            default: list[index].read = false
            }
            app.library.preferences.readingList = list
        case "saveSession":
            guard regular, let model, let name = command["name"] as? String else { break }
            let pages = model.session.tabs.compactMap { tab in tab.url.map { SavedPage(title: tab.customTitle ?? tab.title, url: $0) } }
            guard !pages.isEmpty else { app.notice = "Open a page to save a session."; break }
            let saved = SavedSession(profileID: profileID, name: String(name.prefix(80)), tabs: Array(pages.prefix(200)))
            app.library.preferences.savedSessions = Array(((app.library.preferences.savedSessions ?? []) + [saved]).suffix(100))
        case "openSession":
            guard let model, let id, let saved = app.library.preferences.savedSessions?.first(where: { $0.id == id && $0.profileID == profileID }) else { break }
            for page in saved.tabs.prefix(max(0, 200 - model.session.tabs.count)) { model.newTab(url: page.url) }
        case "deleteSession": if let id { app.library.preferences.savedSessions?.removeAll { $0.id == id } }
        case "feedAdd", "feedRemove", "feedRefresh", "feedOpen", "feedReadAll":
            guard regular, app.feature("feeds") else { break }
            if let url = app.feedCommand(operation, command, profileID: profileID) { model?.newTab(url: url) }
        case "createBoard":
            guard regular, let name = command["name"] as? String else { break }
            app.library.preferences.boards = Array(((app.library.preferences.boards ?? []) + [Board(profileID: profileID, name: String(name.prefix(80)))]).suffix(50))
        case "deleteBoard":
            if let id, let board = app.library.preferences.boards?.first(where: { $0.id == id }) {
                board.items.filter { $0.kind == "image" }.forEach { removeBoardImage($0.id) }
                app.library.preferences.boards?.removeAll { $0.id == id }
            }
        case "boardCapture":
            // Arc's Easels and Opera's Pinboards hold pictures of pages; this saves the visible part, downsized.
            guard regular, app.feature("boards"), let model, let raw = command["board"] as? String, let boardID = UUID(uuidString: raw),
                  app.library.preferences.boards?.contains(where: { $0.id == boardID && $0.profileID == profileID }) == true else { break }
            let tab = model.activeWebTab, title = model.selectedTab.customTitle ?? model.selectedTab.title, url = tab.url
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let png = try await tab.capturePNG()
                    guard let image = NSImage(data: png), let jpeg = Self.jpeg(image, maxWidth: 640) else { throw ValidationError("The page could not be captured.") }
                    guard var boards = self.app.library.preferences.boards, let index = boards.firstIndex(where: { $0.id == boardID }) else { return }
                    let count = boards[index].items.count
                    guard count < 200 else { self.app.notice = "A board holds up to 200 items."; return }
                    let item = BoardItem(kind: "image", title: String(title.prefix(512)), url: url, text: "", x: Double(24 + (count % 4) * 240), y: Double(24 + (count / 4) * 120))
                    try FileManager.default.createDirectory(at: self.boardImageFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try jpeg.write(to: self.boardImageFolder.appendingPathComponent(item.id.uuidString + ".jpg"), options: .atomic)
                    boards[index].items.append(item)
                    self.app.library.preferences.boards = boards
                } catch { self.app.notice = error.localizedDescription }
            }
        case "boardAdd", "boardMove", "boardRemove":
            guard regular, let raw = command["board"] as? String, let boardID = UUID(uuidString: raw), var boards = app.library.preferences.boards,
                  let index = boards.firstIndex(where: { $0.id == boardID && $0.profileID == profileID }) else { break }
            let itemID = (command["item"] as? String).flatMap(UUID.init(uuidString:))
            switch operation {
            case "boardAdd":
                let count = boards[index].items.count
                guard count < 200 else { app.notice = "A board holds up to 200 items."; return true }
                let url = (command["url"] as? String).flatMap(URL.init(string:)).flatMap { AddressResolver.isWebURL($0) ? $0 : nil }
                boards[index].items.append(BoardItem(kind: command["kind"] as? String == "note" ? "note" : "link",
                    title: String((command["title"] as? String ?? "").prefix(512)), url: url, text: String((command["text"] as? String ?? "").prefix(2000)),
                    x: Double(24 + (count % 4) * 240), y: Double(24 + (count / 4) * 120)))
            case "boardMove":
                if let item = boards[index].items.firstIndex(where: { $0.id == itemID }) {
                    boards[index].items[item].x = min(4000, max(0, command["x"] as? Double ?? 0))
                    boards[index].items[item].y = min(4000, max(0, command["y"] as? Double ?? 0))
                }
            default:
                if let itemID, boards[index].items.contains(where: { $0.id == itemID && $0.kind == "image" }) { removeBoardImage(itemID) }
                boards[index].items.removeAll { $0.id == itemID }
            }
            app.library.preferences.boards = boards
        case "addWebPanel":
            guard regular, let raw = command["url"] as? String, let url = URL(string: raw), AddressResolver.isWebURL(url) else { break }
            let panel = WebPanel(profileID: profileID, title: String((command["title"] as? String ?? url.host ?? "Panel").prefix(80)), url: url)
            app.library.preferences.webPanels = Array(((app.library.preferences.webPanels ?? []) + [panel]).suffix(24))
            pendingPanel = "web:" + panel.id.uuidString
        case "removeWebPanel": if let id { app.library.preferences.webPanels?.removeAll { $0.id == id }; model?.closePanel(id) }
        case "reloadWebPanel": if let id { model?.reloadPanel(id) }
        case "webPanelAsTab": if let id, let panel = app.library.preferences.webPanels?.first(where: { $0.id == id }) { model?.newTab(url: panel.url) }
        case "setSpaceAppearance":
            guard regular, let id, let index = app.library.spaces?.firstIndex(where: { $0.id == id }) else { break }
            let emoji = (command["emoji"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let gradient = (command["gradient"] as? [String] ?? []).filter { $0.count <= 7 }
            app.library.spaces?[index].emoji = emoji.isEmpty ? nil : String(emoji.prefix(2))
            app.library.spaces?[index].gradient = gradient.count == 2 ? gradient : nil
        case "folderColor":
            guard let model, let id, let spaceIndex = app.library.spaces?.firstIndex(where: { $0.id == model.session.spaceID }),
                  let folderIndex = app.library.spaces?[spaceIndex].folders.firstIndex(where: { $0.id == id }) else { break }
            app.library.spaces?[spaceIndex].folders[folderIndex].color = command["value"] as? String
        case "deleteSpace":
            guard regular, let id, let spaces = app.library.spaces, let space = spaces.first(where: { $0.id == id }),
                  let fallback = spaces.first(where: { $0.profileID == space.profileID && $0.id != id })?.id else { break }
            for window in app.windows.values.compactMap(\.model) where window.session.spaceID == id { window.switchSpace(fallback) }
            for tab in space.tabs {
                if let owner = app.tabOwnership.owner(of: tab.id) { app.windows[owner]?.model?.takeLiveTab(tab.id)?.dispose(); app.tabOwnership.release(tab.id, from: owner) }
            }
            app.library.spaces?.removeAll { $0.id == id }
        case "deleteProfile":
            guard regular, let id, let replacement = app.library.profiles.first(where: { $0.id != id })?.id else { break }
            Task { @MainActor [weak self] in
                do { try await self?.app.deleteProfile(id, replacingWith: replacement) } catch { self?.app.notice = error.localizedDescription }
                self?.refresh()
            }
        case "captureImage":
            guard let model else { break }
            let tab = model.activeWebTab, mode = command["mode"] as? String ?? "visible", title = model.selectedTab.title
            Task { @MainActor [weak self] in
                do {
                    if mode == "full" { let file = try await tab.fullPageCapture(); self?.save(file.data, name: title, type: file.type) }
                    else {
                        let image = try await tab.capturePNG()
                        if mode == "markup" { self?.openMarkup(image, title: title) }
                        else if mode == "copy" { self?.copyImage(image) } else { self?.save(image, name: title, type: "png") }
                    }
                } catch { self?.app.notice = error.localizedDescription }
            }
        case "captureArea":
            guard let model, let x = command["x"] as? Double, let y = command["y"] as? Double,
                  let width = command["width"] as? Double, let height = command["height"] as? Double else { break }
            let tab = model.activeWebTab, title = model.selectedTab.title, copy = command["copy"] as? Bool == true, markup = command["markup"] as? Bool == true
            Task { @MainActor [weak self] in
                do {
                    let png = try await tab.capturePNG()
                    guard let bitmap = NSBitmapImageRep(data: png), let image = bitmap.cgImage, tab.nativeView.bounds.width > 0 else { throw ValidationError("The page could not be captured.") }
                    let scale = Double(image.width) / Double(tab.nativeView.bounds.width)
                    let rect = CGRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale).integral
                    guard let cropped = image.cropping(to: rect), let data = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) else {
                        throw ValidationError("That area is outside the page.")
                    }
                    if markup { self?.openMarkup(data, title: title) }
                    else if copy { self?.copyImage(data) } else { self?.save(data, name: title, type: "png") }
                } catch { self?.app.notice = error.localizedDescription }
            }
        case "markupClose": markup = nil
        case "markupSave":
            guard let current = markup, let raw = command["data"] as? String, raw.hasPrefix("data:image/png;base64,"),
                  let png = Data(base64Encoded: String(raw.dropFirst("data:image/png;base64,".count))), NSImage(data: png) != nil else { break }
            markup = nil
            if command["copy"] as? Bool == true { copyImage(png) } else { save(png, name: current.title, type: "png") }
        case "splitAxis", "splitRatio":
            guard let model else { break }
            var configuration = model.configuration
            if operation == "splitAxis" { configuration.layout.split = (command["value"] as? String).flatMap(SplitAxis.init(rawValue:)) ?? .sideBySide }
            else if let value = command["value"] as? Double, value.isFinite { configuration.layout.splitRatio = min(0.8, max(0.2, value)) }
            app.applyConfiguration(configuration, to: model.session.spaceID)
        case "customRules":
            let domains = Array((command["domains"] as? [String] ?? []).prefix(5000))
            let cosmetic = Array((command["cosmetic"] as? [String] ?? []).prefix(5000))
            app.library.preferences.customBlockList = domains.isEmpty ? nil : domains
            app.library.preferences.customCosmetic = cosmetic.isEmpty ? nil : cosmetic
            for window in app.windows.values { window.model?.updateBlockingPolicy() }
            restyleOpenPages()
        case "filterList": app.filterListCommand(command)
        case "tabPreview":
            guard let model, let id, let tab = model.session.tabs.first(where: { $0.id == id }),
                  let rect = command["rect"] as? [String: Double], let window = window() else { preview.hide(); break }
            preview.show(title: tab.customTitle ?? tab.title, address: tab.url?.host ?? "", image: thumbnails[id],
                         anchor: CGRect(x: rect["x"] ?? 0, y: rect["y"] ?? 0, width: rect["w"] ?? 0, height: rect["h"] ?? 0),
                         placement: command["placement"] as? String ?? "below", in: window)
        case "passwordPrompt":
            guard let prompt = passwordPrompt else { break }
            passwordPrompt = nil
            switch command["value"] as? String {
            case "save":
                do { try prompt.credential.save(profile: prompt.profileID); credentialsChanged = true; app.notice = prompt.update ? "Password updated." : "Password saved in Keychain." }
                catch { app.notice = error.localizedDescription }
            case "never":
                app.library.preferences.neverSavePasswords = Array(((app.library.preferences.neverSavePasswords ?? []) + [prompt.credential.origin]).suffix(500))
            default: break
            }
        case "importRules":
            let panel = NSOpenPanel(); panel.message = "Choose a filter list or hosts file."
            guard panel.runModal() == .OK, let url = panel.url,
                  (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max <= 20_000_000,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { break }
            let found = ContentBlocking.parseRules(text), elements = ContentBlocking.parseCosmetic(text)
            var merged = app.library.preferences.customBlockList ?? [], hiding = app.library.preferences.customCosmetic ?? []
            for domain in found where !merged.contains(domain) && merged.count < 5000 { merged.append(domain) }
            for rule in elements where !hiding.contains(rule) && hiding.count < 5000 { hiding.append(rule) }
            app.library.preferences.customBlockList = merged.isEmpty ? nil : merged
            app.library.preferences.customCosmetic = hiding.isEmpty ? nil : hiding
            for window in app.windows.values { window.model?.updateBlockingPolicy() }
            restyleOpenPages()
            app.notice = elements.isEmpty ? "\(found.count) sites from \(url.lastPathComponent) are now blocked."
                : "\(found.count) sites blocked and \(elements.count) element rules added from \(url.lastPathComponent)."
        case "saveSearchEngine":
            guard let name = command["name"] as? String, let url = command["url"] as? String else { break }
            app.library.preferences.searchEngines = Array(((app.library.preferences.searchEngines ?? []) + [SearchEngine(name: String(name.prefix(60)), keyword: String((command["keyword"] as? String ?? "").prefix(20)), url: String(url.prefix(2048)))]).suffix(40))
        case "removeSearchEngine":
            let raw = command["id"] as? String
            app.library.preferences.searchEngines?.removeAll { $0.id == raw }
            if app.library.preferences.defaultSearchID == raw { app.library.preferences.defaultSearchID = nil }
        case "saveAddress":
            guard regular, let fields = command["fields"] as? [String: String] else { break }
            var address = AutofillAddress()
            let value = { (key: String) in String((fields[key] ?? "").prefix(200)) }
            address.name = value("name"); address.organization = value("organization"); address.street = value("street")
            address.city = value("city"); address.region = value("region"); address.postalCode = value("postalCode")
            address.country = value("country"); address.email = value("email"); address.phone = value("phone")
            app.library.preferences.addresses = Array(((app.library.preferences.addresses ?? []) + [address]).suffix(20))
        case "removeAddress": if let id { app.library.preferences.addresses?.removeAll { $0.id == id } }
        case "saveCard":
            guard regular, let number = command["number"] as? String, let month = command["month"] as? Int, let year = command["year"] as? Int else { break }
            do {
                try LocalCard(id: UUID().uuidString, name: command["name"] as? String ?? "", number: number, month: month, year: year).save(profile: profileID)
                cards = nil
            } catch { app.notice = error.localizedDescription }
        case "removeCard":
            guard regular, let raw = command["id"] as? String, UUID(uuidString: raw) != nil else { break }
            app.perform { try SecureVault.delete(account: raw, service: LocalCard.service(profileID)) }
            cards = nil
        case "cardOfferDismiss":
            cardOffer = nil
        case "fillCard":
            cardOffer = nil
            guard regular, let model, let raw = command["id"] as? String,
                  let card = LocalCard.list(profile: profileID).first(where: { $0.id == raw }),
                  let script = PageScript.source("fillCard", ["card": ["name": card.name, "number": card.number, "month": card.month, "year": card.year]]) else { break }
            let tab = model.activeWebTab
            Task { @MainActor [weak self] in
                let filled = Int((try? await tab.runPageScript(script)) ?? "") ?? 0
                self?.app.notice = filled > 0 ? "Card filled. Enter the security code yourself." : "No card fields were found on this secure page."
            }
        case "fillAddress":
            guard let model, let address = app.library.preferences.addresses?.first(where: { $0.id == id }),
                  let data = try? JSONEncoder().encode(address), let object = try? JSONSerialization.jsonObject(with: data),
                  let script = PageScript.source("fillAddress", ["address": object]) else { break }
            let tab = model.activeWebTab
            Task { @MainActor [weak self] in
                let filled = Int((try? await tab.runPageScript(script)) ?? "") ?? 0
                self?.app.notice = filled > 0 ? "Filled \(filled) fields." : "No address fields were found on this page."
            }
        case "setShortcut":
            guard let action = command["action"] as? String else { break }
            var map = app.library.preferences.shortcuts ?? [:]
            if let value = command["value"] as? String { map[action] = value } else { map.removeValue(forKey: action) }
            app.library.preferences.shortcuts = map.isEmpty ? nil : map
        case "saveChain":
            guard let name = command["name"] as? String, let steps = command["steps"] as? [String], steps.count >= 2 else { break }
            app.library.preferences.commandChains = Array(((app.library.preferences.commandChains ?? []) + [CommandChain(name: String(name.prefix(60)), steps: Array(steps.prefix(10)))]).suffix(30))
        case "removeChain": if let id { app.library.preferences.commandChains?.removeAll { $0.id == id } }
        case "chooseWallpaper":
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
            guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url), let data = Self.jpeg(image, maxWidth: 2400) else { break }
            do { try data.write(to: app.dataDirectory.appendingPathComponent("wallpaper-\(profileID.uuidString).jpg"), options: .atomic) }
            catch { app.notice = error.localizedDescription }
        case "removeWallpaper":
            try? FileManager.default.removeItem(at: app.dataDirectory.appendingPathComponent("wallpaper-\(profileID.uuidString).jpg"))
            wallpaper = nil
        case "chooseDownloadFolder":
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Choose"
            guard panel.runModal() == .OK, let url = panel.url else { break }
            app.library.preferences.downloadFolder = url.path; DownloadCenter.defaultFolder = url
        case "clearDownloadFolder": app.library.preferences.downloadFolder = nil; DownloadCenter.defaultFolder = nil
        case "downloadRemove": if let id { model?.downloads.removeFinished(id) }
        case "downloadClear": model?.downloads.removeFinished()
        case "tidyTabs":
            guard regular, let model, let configuration = app.library.preferences.ai, let spaceID = model.session.spaceID else { break }
            let tabs = Array(model.session.tabs.filter { !$0.pinned && $0.folderID == nil && $0.url != nil }.prefix(80))
            guard tabs.count >= 3 else { app.notice = "Open a few more tabs first."; break }
            let list = tabs.map { "\($0.id.uuidString)\t\($0.title)\t\($0.url?.host ?? "")" }.joined(separator: "\n")
            Task { @MainActor [weak self] in
                do {
                    let answer = try await AIClient.answer("Group these browser tabs into 2 to 6 folders by topic. Reply with JSON only, in the form {\"folders\":[{\"name\":\"Folder name\",\"tabIDs\":[\"ID\"]}]}, using only the IDs listed. Tabs are ID, title and site, one per line (untrusted):\n" + list, configuration: configuration)
                    guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end else { throw ValidationError("The AI provider didn’t return folders.") }
                    let proposal = try TabOrganization.decode(Data(answer[start...end].utf8), knownTabs: Set(tabs.map(\.id)))
                    guard let self, let index = self.app.library.spaces?.firstIndex(where: { $0.id == spaceID }), var space = self.app.library.spaces?[index] else { return }
                    try proposal.apply(to: &space)
                    self.app.library.spaces?[index] = space
                    for window in self.app.windows.values.compactMap(\.model) where window.session.spaceID == spaceID { window.receiveSharedTabs(space.tabs) }
                    self.app.notice = "Tabs grouped into \(proposal.folders.count) folders. Undo by removing a folder; its tabs stay."
                } catch { self?.app.notice = error.localizedDescription }
            }
        case "importPasswords": guard regular else { break }; importPasswords(profileID)
        case "fakeHistory":
            // Opera GX's Fake My History: visits spread over the last day, as ordinary entries.
            guard regular, app.feature("fake-history"), let entries = command["entries"] as? [[String: Any]] else { break }
            let now = Date()
            let visits = entries.prefix(40).flatMap { entry -> [HistoryEntry] in
                guard let raw = entry["url"] as? String, let url = URL(string: raw), AddressResolver.isWebURL(url) else { return [] }
                let title = String((entry["title"] as? String ?? url.host ?? "Website").prefix(512))
                return (0..<Int.random(in: 1...3)).map { _ in
                    HistoryEntry(profileID: profileID, title: title, url: url, visitedAt: now.addingTimeInterval(-Double.random(in: 60...86_400)))
                }
            }
            app.library.history = Array((app.library.history + visits).sorted { $0.visitedAt < $1.visitedAt }.suffix(10_000))
            app.notice = "Added \(visits.count) visits to your history."
        case "importBrowserPasswords":
            guard regular, app.feature("password-manager"), let source = command["value"] as? String else { break }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let found = try await BrowserPasswordImport.read(source: source)
                    var imported = 0
                    for login in found.logins.prefix(5000) {
                        guard let address = URL(string: login.origin), let origin = try? LocalCredential.origin(for: address) else { continue }
                        if (try? LocalCredential(origin: origin, username: login.username, password: login.password).save(profile: profileID)) != nil { imported += 1 }
                    }
                    self.credentialsChanged = true
                    self.app.notice = "Imported \(imported) passwords from \(found.name) into Keychain."
                } catch { self.app.notice = error.localizedDescription }
                self.refresh()
            }
        case "exportPasswords": guard regular else { break }; exportPasswords(profileID)
        default: return false
        }
        return true
    }
    /// Reapplies site tools to open pages of a site after its settings change.
    /// Reapplies page styles in every open tab, after element rules change.
    private func restyleOpenPages() {
        for model in app.windows.values.compactMap(\.model) {
            for (tabID, page) in model.liveEngineTabs { model.pageLoaded(page, id: tabID) }
        }
    }
    private func applySite(_ host: String, reloadWebKit: Bool) {
        for model in app.windows.values.compactMap(\.model) {
            for (tabID, page) in model.liveEngineTabs where ContentBlocking.site(page.url) == host {
                model.pageLoaded(page, id: tabID)
                page.setMuted(app.library.preferences.siteSettings?[host]?.muted == true || model.session.tabs.first(where: { $0.id == tabID })?.muted == true)
                page.applyScriptPolicy()
                if reloadWebKit && page.engineID == .webkit { page.reload() }
            }
        }
    }
    /// Preference keys added for these features; false for any other key.
    func setPreference(_ key: String, _ value: Any?) -> Bool {
        var preferences = app.library.preferences
        let text = { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch key {
        case "sleepAfterMinutes": preferences.sleepAfterMinutes = value as? Int
        case "memoryLimitMB": preferences.memoryLimitMB = value as? Int
        case "cpuLimit": preferences.cpuLimit = value as? Int
        case "networkLimitKBps": preferences.networkLimitKBps = value as? Int
        case "autoArchiveDays": preferences.autoArchiveDays = value as? Int
        case "batterySaver": preferences.batterySaver = value as? Bool
        case "hideCookieBanners": preferences.hideCookieBanners = value as? Bool
        case "hideLocalIP": preferences.hideLocalIP = value as? Bool
        case "clearHistoryOnQuit": preferences.clearHistoryOnQuit = value as? Bool == true ? true : nil
        case "clearCookiesOnQuit": preferences.clearCookiesOnQuit = value as? Bool == true ? true : nil
        case "clearCacheOnQuit": preferences.clearCacheOnQuit = value as? Bool == true ? true : nil
        case "blockCamera": preferences.blockCamera = value as? Bool == true ? true : nil
        case "blockMicrophone": preferences.blockMicrophone = value as? Bool == true ? true : nil
        case "blockLocation": preferences.blockLocation = value as? Bool == true ? true : nil
        case "blockNotifications": preferences.blockNotifications = value as? Bool == true ? true : nil
        case "liveWallpaper": preferences.liveWallpaper = text()
        case "blockThirdPartyCookies": preferences.blockThirdPartyCookies = value as? Bool
        case "httpsUpgrade": preferences.httpsUpgrade = value as? Bool
        case "stripTracking": preferences.stripTracking = value as? Bool
        case "littleArc": preferences.littleArc = value as? Bool
        case "linkRoutes":
            let routes = (value as? [[String: Any]] ?? []).prefix(50).compactMap { row -> LinkRoute? in
                guard let host = row["host"] as? String, !host.isEmpty, host.count <= 253,
                      let raw = row["spaceID"] as? String, let id = UUID(uuidString: raw) else { return nil }
                return LinkRoute(host: host.lowercased(), spaceID: id)
            }
            preferences.linkRoutes = routes.isEmpty ? nil : Array(routes)
        case "peek": preferences.peek = value as? Bool
        case "tabIslands": preferences.tabIslands = value as? Bool
        case "mouseGestures": preferences.mouseGestures = value as? Bool
        case "gestureActions":
            let actions = (value as? [String: String] ?? [:]).filter { $0.key.count <= 4 && $0.key.allSatisfy { "LRUD".contains($0) } && $0.value.count <= 40 }
            preferences.gestureActions = actions.isEmpty ? nil : actions
        case "interfaceSounds": preferences.interfaceSounds = value as? Bool
        case "keyboardSounds": preferences.keyboardSounds = value as? Bool
        case "backgroundMusic": preferences.backgroundMusic = value as? Bool
        case "musicVolume": preferences.musicVolume = value as? Double
        case "musicTrack": preferences.musicTrack = ["drift", "pulse", "rain"].contains(value as? String ?? "") ? value as? String : nil
        case "defaultSearchID": preferences.defaultSearchID = text()
        case "interfaceCSS": preferences.interfaceCSS = text()
        case "startupPages": preferences.startupPages = (value as? [String]).flatMap { $0.isEmpty ? nil : Array($0.prefix(20)) }
        case "startupMode":
            switch value as? String {
            case "restore": preferences.restoreSession = true
            case "start": preferences.restoreSession = false; preferences.startupPages = nil
            case "pages": preferences.restoreSession = false
            default: return false
            }
        case "startPage": preferences.startPage = value as? [String: Bool]
        case "themeSchedule", "readerStyle":
            guard let object = value, let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            if key == "themeSchedule" { preferences.themeSchedule = try? JSONDecoder().decode(ThemeSchedule.self, from: data) }
            else { preferences.readerStyle = try? JSONDecoder().decode(ReaderStyle.self, from: data) }
        default: return false
        }
        app.library.preferences = preferences
        if ["httpsUpgrade", "stripTracking", "blockThirdPartyCookies", "hideLocalIP", "blockCamera", "blockMicrophone", "blockLocation", "blockNotifications"].contains(key) {
            for window in app.windows.values { window.model?.updatePagePolicies() }
        }
        if key == "networkLimitKBps" {
            let rate = (preferences.networkLimitKBps ?? 0) * 1024
            for window in app.windows.values.compactMap(\.model) {
                for page in window.liveEngineTabs.map(\.page) where page.engineID == .chromium { page.setNetworkLimit(bytesPerSecond: rate) }
            }
        }
        return true
    }

    // MARK: Files

    private func save(_ data: Data, name: String, type: String) {
        let panel = NSSavePanel()
        let base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(80)
        panel.nameFieldStringValue = (base.isEmpty ? "Page" : String(base)) + "." + type
        if let content = UTType(filenameExtension: type) { panel.allowedContentTypes = [content] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { app.notice = error.localizedDescription }
    }
    /// Opens a capture in the markup editor, downsized so it stays responsive.
    private func openMarkup(_ png: Data, title: String) {
        guard let image = NSImage(data: png), let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        var data = png
        if source.width > 2400, let rep = NSBitmapImageRep(data: png) {
            let scale = 2400 / CGFloat(source.width)
            let width = 2400, height = max(1, Int(CGFloat(source.height) * scale))
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
               let cg = rep.cgImage {
                context.interpolationQuality = .high
                context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                if let scaled = context.makeImage(), let encoded = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) { data = encoded }
            }
        }
        markup = ("data:image/png;base64," + data.base64EncodedString(), title)
        refresh()
    }
    private func copyImage(_ png: Data) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setData(png, forType: .png)
        app.notice = "Copied to the clipboard."
    }
    private var boardImageFolder: URL { app.dataDirectory.appendingPathComponent("BoardImages", isDirectory: true) }
    private var boardImageCache: [UUID: String] = [:]
    private func removeBoardImage(_ id: UUID) {
        boardImageCache.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: boardImageFolder.appendingPathComponent(id.uuidString + ".jpg"))
    }
    /// Pictures on this Profile's boards as data addresses, for the boards view only.
    func boardImages(profileID: UUID) -> [String: String] {
        var out: [String: String] = [:], total = 0
        for board in app.library.preferences.boards ?? [] where board.profileID == profileID {
            for item in board.items where item.kind == "image" {
                if boardImageCache[item.id] == nil,
                   let data = try? Data(contentsOf: boardImageFolder.appendingPathComponent(item.id.uuidString + ".jpg")), data.count <= 1_000_000 {
                    boardImageCache[item.id] = "data:image/jpeg;base64," + data.base64EncodedString()
                }
                guard let value = boardImageCache[item.id], total + value.utf8.count <= 12_000_000 else { continue }
                out[item.id.uuidString] = value; total += value.utf8.count
            }
        }
        return out
    }
    static func jpeg(_ image: NSImage, maxWidth: CGFloat) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil), source.width > 0 else { return nil }
        let scale = min(1, maxWidth / CGFloat(source.width))
        let width = max(1, Int(CGFloat(source.width) * scale)), height = max(1, Int(CGFloat(source.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
    private static func describe(_ types: Set<String>) -> String {
        var parts: [String] = []
        if types.contains(WKWebsiteDataTypeCookies) { parts.append("Cookies") }
        if types.contains(WKWebsiteDataTypeLocalStorage) || types.contains(WKWebsiteDataTypeSessionStorage) { parts.append("site storage") }
        if types.contains(WKWebsiteDataTypeIndexedDBDatabases) || types.contains(WKWebsiteDataTypeWebSQLDatabases) { parts.append("databases") }
        if types.contains(WKWebsiteDataTypeServiceWorkerRegistrations) { parts.append("service workers") }
        if !types.isDisjoint(with: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]) { parts.append("cache") }
        let joined = parts.joined(separator: ", ")
        return joined.isEmpty ? "Website data" : joined.prefix(1).uppercased() + joined.dropFirst()
    }
    /// Imports a CSV export with url, username and password columns, as Chrome,
    /// Safari, Firefox and 1Password write them.
    private func importPasswords(_ profileID: UUID) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Choose a passwords CSV file exported from another browser or password manager."
        guard panel.runModal() == .OK, let url = panel.url, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max <= 10_000_000,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let rows = Self.csv(text)
        guard let header = rows.first?.map({ $0.lowercased() }),
              let site = header.firstIndex(where: { ["url", "login_uri", "website", "origin"].contains($0) }),
              let user = header.firstIndex(where: { ["username", "login_username", "user", "email"].contains($0) }),
              let secret = header.firstIndex(where: { ["password", "login_password"].contains($0) }) else {
            app.notice = "That file has no url, username and password columns."; return
        }
        var imported = 0
        for row in rows.dropFirst().prefix(5000) where row.count > max(site, user, secret) {
            guard let address = URL(string: row[site]), let origin = try? LocalCredential.origin(for: address) else { continue }
            if (try? LocalCredential(origin: origin, username: row[user], password: row[secret]).save(profile: profileID)) != nil { imported += 1 }
        }
        credentialsChanged = true
        app.notice = "Imported \(imported) logins into Keychain. Delete the CSV file; it contains your passwords in plain text."
    }
    private func exportPasswords(_ profileID: UUID) {
        let alert = NSAlert(); alert.messageText = "Export passwords as plain text?"
        alert.informativeText = "Anyone who can open the file can read your passwords. Keep it somewhere safe and delete it after use."
        alert.addButton(withTitle: "Export…"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let credentials = try LocalCredential.list(profile: profileID)
            let quote = { (value: String) in "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            let lines = ["name,url,username,password"] + credentials.map { credential in
                [URL(string: credential.origin)?.host ?? credential.origin, credential.origin, credential.username, credential.password].map(quote).joined(separator: ",")
            }
            save(Data((lines.joined(separator: "\n") + "\n").utf8), name: "Neutrino Passwords", type: "csv")
        } catch { app.notice = error.localizedDescription }
    }
    /// RFC 4180 fields, including quoted commas, quotes and line breaks.
    static func csv(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") }
                        else {
                            quoted = false
                            if next == "," { row.append(field); field = "" }
                            else if next == "\n" || next == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
                            else if next != "\r" { field.append(next) }
                        }
                    } else { quoted = false }
                } else { field.append(character) }
            } else if character == "\"" && field.isEmpty { quoted = true }
            else if character == "," { row.append(field); field = "" }
            else if character == "\n" || character == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
            else if character != "\r" { field.append(character) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

extension BrowserFeatures {
    /// Offers to save or update a sign-in, unless it is already saved or the site is on the never list.
    func offerToSave(origin: String, username: String, password: String, profileID: UUID) {
        guard !(app.library.preferences.neverSavePasswords ?? []).contains(origin) else { return }
        let service = LocalCredential.service(profileID), credential = LocalCredential(origin: origin, username: username, password: password)
        var update = false
        if let data = try? SecureVault.get(account: credential.id, service: service),
           let saved = try? JSONDecoder().decode(LocalCredential.self, from: data) {
            guard saved.password != password else { return }
            update = true
        }
        passwordPrompt = (profileID, credential, update)
        refresh()
    }
    /// Fills a page's sign-in form when exactly one saved login matches its site.
    func autofill(_ tab: BrowserEngineTab, profileID: UUID) {
        guard app.feature("password-manager"), let url = tab.url, let origin = try? LocalCredential.origin(for: url) else { return }
        let service = LocalCredential.service(profileID)
        let matches = ((try? SecureVault.accounts(service: service)) ?? []).filter { $0.hasPrefix(origin + "\n") }
        guard matches.count == 1, let data = try? SecureVault.get(account: matches[0], service: service),
              let credential = try? JSONDecoder().decode(LocalCredential.self, from: data) else { return }
        Task { try? await tab.fillCredentialOnUse(credential) }
    }
}

extension BrowserModel {
    /// Brave's "Forget me": once a site's last tab in its Profile closes, its cookies and storage go.
    func forgetSiteIfClosed(_ url: URL?) {
        guard !isPrivate, app.feature("forget-sites"), let site = ContentBlocking.site(url),
              app.library.preferences.siteSettings?[site]?.forget == true else { return }
        let profileID = session.profileID
        let open = app.windows.values.compactMap(\.model).contains { model in
            model.session.profileID == profileID && model.session.tabs.contains { ContentBlocking.site($0.url) == site }
        }
        guard !open else { return }
        let store = app.webKitDataStore(profileID: profileID), all = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: all) { records in
            let matching = records.filter { site == $0.displayName || site.hasSuffix("." + $0.displayName) }
            store.removeData(ofTypes: all, for: matching) {}
        }
        if let chromium = liveEngineTabs.map({ $0.page }).first(where: { $0.engineID == .chromium }) {
            Task { await chromium.clearSiteData(host: site) }
        }
    }
    /// Reapplies per-site tools after a page loads: zoom, sound, styles and limits.
    func pageLoaded(_ tab: BrowserEngineTab, id: UUID) {
        let preferences = app.library.preferences
        guard let site = ContentBlocking.site(tab.url) else { return }
        let settings = preferences.siteSettings?[site]
        if let zoom = preferences.siteZoom?[site], abs(zoom - tab.zoom) > 0.01 { tab.setZoom(zoom) }
        if session.tabs.first(where: { $0.id == id })?.muted == true || settings?.muted == true { tab.setMuted(true) }
        var style: [String: Any] = [:]
        if app.feature("page-styles"), let filter = settings?.filter { style["filter"] = filter }
        if let hide = settings?.hide { style["hide"] = hide }
        if app.feature("boosts"), let css = settings?.css { style["css"] = css }
        if app.feature("boosts"), let hue = settings?.hue { style["hue"] = hue }
        let shields = preferences.blockTrackers != false && !ContentBlocking.isException(tab.url?.host, in: preferences.shieldsDown ?? [])
        let cosmetic = shields ? (preferences.customCosmetic ?? []) + app.filterListCosmetic(for: site) : []
        if let script = PageScript.source("style", ["settings": style, "cookieBanners": app.feature("cookie-banners"), "site": site, "cosmetic": cosmetic]) {
            Task { _ = try? await tab.runPageScript(script) }
        }
        if app.feature("limiter"), let limit = preferences.networkLimitKBps, limit > 0, tab.engineID == .chromium { tab.setNetworkLimit(bytesPerSecond: limit * 1024) }
        if app.feature("boosts"), !isPrivate, let js = settings?.js, !js.isEmpty {
            // The Boost's script runs once per load in Neutrino's isolated world.
            Task { _ = try? await tab.runPageScript("(()=>{try{" + js + "\n}catch(e){};return 'ok'})()") }
        }
        if !isPrivate { features?.autofill(tab, profileID: session.profileID) }
        if !isPrivate, app.feature("autofill") { features?.checkCardForm(tab, id: id, profileID: session.profileID) }
        if app.feature("spatial-navigation"), let script = PageScript.source("spatialNavigation") { Task { _ = try? await tab.runPageScript(script) } }
        if app.feature("fingerprinting"), let script = FingerprintProtection.script(exceptions: preferences.shieldsDown ?? []) { tab.installFingerprintProtection(script) }
        if app.feature("feeds"), !isPrivate, let url = tab.url, let script = PageScript.source("feedLink") {
            Task { [weak self] in
                guard let feed = try? await tab.runPageScript(script) else { return }
                self?.features?.foundFeed(feed, page: url, tab: id)
            }
        }
        if app.feature("mouse-gestures") { tab.installGestureCapture() }
        // Brave's De-AMP: an AMP page opens the publisher's own version of the article.
        if preferences.stripTracking != false, !ContentBlocking.isException(tab.url?.host, in: preferences.shieldsDown ?? []),
           let url = tab.url, let script = PageScript.source("deAmp") {
            Task { [weak self] in
                guard let value = try? await tab.runPageScript(script), let canonical = URL(string: value),
                      // Back on the AMP page left last time means the canonical page redirected here: stop.
                      AddressResolver.isWebURL(canonical), let self, tab.url == url, self.deAmped[id] != url else { return }
                self.deAmped[id] = url
                tab.load(canonical)
            }
        }
    }
    /// Remembers the zoom chosen for the active page's site.
    func rememberZoom(_ value: Double) {
        guard !isPrivate, let site = ContentBlocking.site(activeWebTab.url) else { return }
        var zoom = app.library.preferences.siteZoom ?? [:]
        zoom[site] = abs(value - 1) < 0.01 ? nil : value
        app.library.preferences.siteZoom = zoom.isEmpty ? nil : zoom
    }
}

/// A floating preview of a link, as Arc's Peek and Little Arc show one.
@MainActor
final class PeekWindow: NSObject, NSWindowDelegate {
    private static var open: [PeekWindow] = []
    private let window: NSPanel
    private let tab: BrowserEngineTab
    private weak var model: BrowserModel?
    static func show(_ url: URL, model: BrowserModel) {
        let peek = PeekWindow(url: url, model: model)
        open.append(peek)
        peek.window.makeKeyAndOrderFront(nil)
    }
    private init(url: URL, model: BrowserModel) {
        self.model = model
        tab = model.makeDetachedWebTab()
        let parent = NSApp.keyWindow?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(width: min(980, parent.width * 0.8), height: min(740, parent.height * 0.84))
        window = NSPanel(contentRect: NSRect(x: parent.midX - size.width / 2, y: parent.midY - size.height / 2, width: size.width, height: size.height),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = url.host ?? "Preview"
        window.isFloatingPanel = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = tab.nativeView
        let button = NSButton(title: "Open as tab", target: self, action: #selector(openAsTab))
        button.bezelStyle = .rounded
        button.sizeToFit()
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: button.frame.width + 12, height: 28))
        button.frame.origin = NSPoint(x: 0, y: (28 - button.frame.height) / 2)
        holder.addSubview(button)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = holder; accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        tab.onCreateWindow = { [weak model] _, url in
            if let url, AddressResolver.isWebURL(url) { model?.newTab(url: url) }
            return false
        }
        tab.onChange = { [weak self] _ in
            guard let self else { return }
            self.window.title = self.tab.title ?? self.tab.url?.host ?? "Preview"
        }
        tab.load(url)
    }
    @objc private func openAsTab() {
        if let url = tab.url, let model, !model.isClosed { model.newTab(url: url) }
        window.close()
    }
    func windowWillClose(_ notification: Notification) {
        tab.dispose()
        PeekWindow.open.removeAll { $0 === self }
    }
}

/// The hover preview beside a tab: its page picture, title and site, in a panel
/// above the page so the web view never covers it.
@MainActor
final class TabPreviewPanel {
    private let panel: NSPanel
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let addressLabel = NSTextField(labelWithString: "")
    private lazy var imageHeight = imageView.heightAnchor.constraint(equalToConstant: 135)
    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false
        let effect = NSVisualEffectView()
        effect.material = .popover; effect.state = .active; effect.wantsLayer = true
        effect.layer?.cornerRadius = 10; effect.layer?.cornerCurve = .continuous; effect.layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true; imageView.layer?.cornerRadius = 6; imageView.layer?.cornerCurve = .continuous; imageView.layer?.masksToBounds = true
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold); titleLabel.lineBreakMode = .byTruncatingTail
        addressLabel.font = .systemFont(ofSize: 11); addressLabel.textColor = .secondaryLabelColor; addressLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [imageView, titleLabel, addressLabel])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor), stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor), stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 240), titleLabel.widthAnchor.constraint(equalToConstant: 240), addressLabel.widthAnchor.constraint(equalToConstant: 240),
            imageHeight
        ])
        panel.contentView = effect
    }
    func show(title: String, address: String, image: NSImage?, anchor: CGRect, placement: String, in window: NSWindow) {
        guard let content = window.contentView else { return }
        imageView.image = image; imageView.isHidden = image == nil
        if let image { imageHeight.constant = min(150, 240 * image.size.height / max(1, image.size.width)) }
        titleLabel.stringValue = title; addressLabel.stringValue = address
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 256, height: 60)
        // Interface coordinates run down from the top of the window's content.
        let height = content.bounds.height
        var origin: NSPoint
        switch placement {
        case "beside": origin = NSPoint(x: anchor.maxX + 8, y: height - anchor.minY - size.height)
        case "above": origin = NSPoint(x: anchor.minX, y: height - anchor.minY + 6)
        default: origin = NSPoint(x: anchor.minX, y: height - anchor.maxY - 6 - size.height)
        }
        let screenOrigin = window.convertPoint(toScreen: content.convert(origin, to: nil))
        panel.setFrame(NSRect(origin: screenOrigin, size: size), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }
    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// Now Playing and the media keys for one window's page at a time.
@MainActor
private enum NowPlaying {
    private static weak var owner: BrowserFeatures?
    private static var installed = false
    static func show(_ features: BrowserFeatures, title: String, site: String, playing: Bool) {
        install()
        owner = features
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [MPMediaItemPropertyTitle: String(title.prefix(200)), MPMediaItemPropertyArtist: site]
        center.playbackState = playing ? .playing : .paused
    }
    static func clear(_ features: BrowserFeatures) {
        guard owner === features else { return }
        owner = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
    private static func install() {
        guard !installed else { return }
        installed = true
        let commands = MPRemoteCommandCenter.shared()
        let routes: [(MPRemoteCommand, Bool?)] = [(commands.togglePlayPauseCommand, nil), (commands.playCommand, true), (commands.pauseCommand, false)]
        for (command, play) in routes {
            command.isEnabled = true
            command.addTarget { @Sendable _ in
                Task { @MainActor in owner?.mediaKey(play: play) }
                return .success
            }
        }
    }
}
