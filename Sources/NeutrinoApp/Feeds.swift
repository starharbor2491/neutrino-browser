// SPDX-License-Identifier: MPL-2.0
import Foundation
import NeutrinoCore

/// Vivaldi's Feeds panel: RSS and Atom feeds fetched from their publishers,
/// parsed on this Mac and refreshed every 30 minutes.
extension AppState {
    private static let feedInterval: TimeInterval = 30 * 60

    func feedCommand(_ operation: String, _ command: [String: Any], profileID: UUID) -> URL? {
        let id = (command["id"] as? String).flatMap(UUID.init(uuidString:))
        var feeds = library.preferences.feeds ?? []
        switch operation {
        case "feedAdd":
            guard let raw = command["url"] as? String, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? ""), url.host != nil else {
                notice = "Enter the address of an RSS or Atom feed."; return nil
            }
            guard !feeds.contains(where: { $0.profileID == profileID && $0.url == url }) else { notice = "You’re already subscribed to that feed."; return nil }
            guard feeds.filter({ $0.profileID == profileID }).count < 100 else { notice = "Remove a feed before adding another."; return nil }
            feeds.append(FeedSubscription(profileID: profileID, title: url.host ?? "Feed", url: url))
            library.preferences.feeds = feeds
            Task { await refreshFeeds(force: true, only: url) }
        case "feedRemove":
            feeds.removeAll { $0.id == id && $0.profileID == profileID }
            library.preferences.feeds = feeds.isEmpty ? nil : feeds
        case "feedRefresh":
            Task { await refreshFeeds(force: true) }
        case "feedOpen":
            for f in feeds.indices where feeds[f].profileID == profileID {
                guard let e = feeds[f].entries.firstIndex(where: { $0.id == id }) else { continue }
                feeds[f].entries[e].read = true
                library.preferences.feeds = feeds
                return feeds[f].entries[e].url
            }
        case "feedReadAll":
            for f in feeds.indices where feeds[f].profileID == profileID {
                for e in feeds[f].entries.indices { feeds[f].entries[e].read = true }
            }
            library.preferences.feeds = feeds
        default: break
        }
        return nil
    }

    /// Fetches feeds last fetched more than 30 minutes ago, or all of them when forced.
    func refreshFeeds(force: Bool, only: URL? = nil) async {
        guard !feedsRefreshing else { return }
        let due = (library.preferences.feeds ?? []).filter { feed in
            (only == nil || feed.url == only) && (force || feed.updatedAt.map { Date().timeIntervalSince($0) > Self.feedInterval } ?? true)
        }
        guard !due.isEmpty else { return }
        feedsRefreshing = true
        defer { feedsRefreshing = false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        for feed in due.prefix(100) {
            var result = feed
            do {
                let (data, response) = try await session.data(from: feed.url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ValidationError("The site didn’t return its feed.") }
                guard data.count <= 5_000_000 else { throw ValidationError("The feed is larger than 5 MB.") }
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                guard let parsed = try RustCore.request(["op": "parseFeed", "value": text]) as? [String: Any] else { throw ValidationError("That address doesn’t return a valid RSS or Atom feed.") }
                if let title = parsed["title"] as? String, !title.isEmpty { result.title = String(title.prefix(120)) }
                result.entries = Self.merge(parsed["entries"] as? [[String: Any]] ?? [], into: feed.entries)
                result.updatedAt = Date(); result.error = nil
            } catch {
                result.updatedAt = Date(); result.error = error.localizedDescription
            }
            // The feed may have been removed while it downloaded.
            if let index = library.preferences.feeds?.firstIndex(where: { $0.id == feed.id }) {
                result.entries = result.entries.map { entry in
                    var entry = entry
                    if library.preferences.feeds?[index].entries.first(where: { $0.url == entry.url })?.read == true { entry.read = true }
                    return entry
                }
                library.preferences.feeds?[index] = result
            }
        }
    }

    /// New entries first, keeping each known entry's identity and read state, at most 100 per feed.
    private static func merge(_ parsed: [[String: Any]], into existing: [FeedEntry]) -> [FeedEntry] {
        var known = Dictionary(existing.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [FeedEntry] = []
        for item in parsed {
            guard let raw = item["url"] as? String, let url = URL(string: raw), out.allSatisfy({ $0.url != url }) else { continue }
            let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) } ?? url.host ?? raw
            let time = date(item["date"] as? String ?? "")
            let display = time.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            if var entry = known.removeValue(forKey: url) {
                entry.title = title; entry.time = time ?? entry.time; entry.date = time == nil ? entry.date : display
                out.append(entry)
            } else {
                out.append(FeedEntry(title: title, url: url, time: time ?? Date(), date: display))
            }
        }
        out += existing.filter { known[$0.url] != nil }
        return Array(out.sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }.prefix(100))
    }

    /// RSS dates (RFC 822) and Atom dates (ISO 8601).
    private static func date(_ value: String) -> Date? {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = options
            if let date = iso.date(from: value) { return date }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm zzz", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
