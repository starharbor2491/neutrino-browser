// SPDX-License-Identifier: MPL-2.0
import Foundation
import NeutrinoCore

/// Filter lists people subscribe to, as Brave, Vivaldi and Opera offer. Each list
/// downloads from its publisher, is parsed on this Mac and refreshes once a week.
extension AppState {
    private var filterListFolder: URL { dataDirectory.appendingPathComponent("FilterLists", isDirectory: true) }
    private struct SavedList: Codable { var domains: [String]; var cosmetic: [String] }

    /// Loads the saved rules of every enabled list and reapplies blocking.
    func loadFilterLists() {
        var domains: [String] = [], generic: [String] = [], bySite: [String: [String]] = [:]
        for list in library.preferences.filterLists ?? [] where list.enabled {
            guard let data = try? Data(contentsOf: filterListFolder.appendingPathComponent(list.id + ".json")),
                  let saved = try? JSONDecoder().decode(SavedList.self, from: data) else { continue }
            domains += saved.domains
            for rule in saved.cosmetic {
                guard let marker = rule.range(of: "##") else { continue }
                let hosts = rule[..<marker.lowerBound].split(separator: ",").map(String.init).filter { !$0.hasPrefix("~") }
                if hosts.isEmpty { generic.append(rule) }
                else { for host in hosts { bySite[host, default: []].append(rule) } }
            }
        }
        filterListDomains = Array(domains.prefix(120_000))
        filterListGenericCosmetic = Array(generic.prefix(4000))
        filterListSiteCosmetic = bySite
        for window in windows.values { window.model?.updateBlockingPolicy() }
    }

    /// Element rules for a site from subscribed lists: generic ones and those naming the site or a parent domain.
    func filterListCosmetic(for site: String) -> [String] {
        var rules = filterListGenericCosmetic
        var host = Substring(site)
        while !host.isEmpty {
            rules += filterListSiteCosmetic[String(host)] ?? []
            guard let dot = host.firstIndex(of: ".") else { break }
            host = host[host.index(after: dot)...]
        }
        return rules
    }

    /// Downloads enabled lists that are missing or older than a week, or all of them when forced.
    func refreshFilterLists(force: Bool) async {
        let week: TimeInterval = 7 * 86_400
        let due = (library.preferences.filterLists ?? []).filter { list in
            list.enabled && (force || list.updatedAt.map { Date().timeIntervalSince($0) > week } ?? true)
        }
        guard !due.isEmpty else { return }
        try? FileManager.default.createDirectory(at: filterListFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        for list in due {
            var result = list
            do {
                guard list.url.scheme == "https" else { throw ValidationError("Filter lists must use an https:// address.") }
                let (data, response) = try await session.data(from: list.url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ValidationError("The list’s publisher didn’t return the list.") }
                guard data.count <= 20_000_000 else { throw ValidationError("The list is larger than 20 MB.") }
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                let parsed = try ContentBlocking.parseFilterList(text)
                guard !parsed.domains.isEmpty || !parsed.cosmetic.isEmpty else { throw ValidationError("No rules Neutrino can use were found in this list.") }
                try JSONEncoder().encode(SavedList(domains: parsed.domains, cosmetic: parsed.cosmetic))
                    .write(to: filterListFolder.appendingPathComponent(list.id + ".json"), options: .atomic)
                result.updatedAt = Date(); result.domains = parsed.domains.count; result.cosmetic = parsed.cosmetic.count; result.error = nil
            } catch {
                result.error = error.localizedDescription
            }
            if let index = library.preferences.filterLists?.firstIndex(where: { $0.id == list.id }) {
                library.preferences.filterLists?[index] = result
            }
        }
        loadFilterLists()
    }

    /// Settings actions: turn a list on or off, add one by address, remove one, refresh all.
    func filterListCommand(_ command: [String: Any]) {
        var lists = library.preferences.filterLists ?? []
        let id = (command["id"] as? String ?? "").filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(64)
        switch command["action"] as? String {
        case "toggle":
            guard !id.isEmpty else { return }
            if let index = lists.firstIndex(where: { $0.id == String(id) }) { lists[index].enabled.toggle() }
            else if let raw = command["url"] as? String, let url = URL(string: raw), url.scheme == "https" {
                lists.append(FilterList(id: String(id), title: String((command["title"] as? String ?? raw).prefix(80)), url: url))
            }
        case "add":
            guard let raw = command["url"] as? String, let url = URL(string: raw), url.scheme == "https", url.host != nil,
                  !lists.contains(where: { $0.url == url }), lists.count < 30 else { notice = "Enter the https:// address of a filter list."; return }
            let digest = raw.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
            lists.append(FilterList(id: "list-" + String(digest, radix: 36), title: url.host ?? "Filter list", url: url))
        case "remove":
            lists.removeAll { $0.id == String(id) }
            try? FileManager.default.removeItem(at: filterListFolder.appendingPathComponent(String(id) + ".json"))
        case "refresh": break
        default: return
        }
        library.preferences.filterLists = lists.isEmpty ? nil : lists
        loadFilterLists()
        Task { await refreshFilterLists(force: command["action"] as? String == "refresh") }
    }
}
