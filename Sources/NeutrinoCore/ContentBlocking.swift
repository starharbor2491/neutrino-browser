// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum ContentBlocking {
  /// Hosts blocked at a level: trackers always, ads when `ads` is true, plus the person's rules.
  public static func domains(ads: Bool = true, custom: [String] = []) -> [String] {
    (try? RustCore.request(["op": "blockingDomains", "ads": ads, "custom": custom]) as? [String]) ?? []
  }
  public static func blocks(_ url: URL, topLevel: Bool = false, ads: Bool = true) -> Bool {
    (try? RustCore.request(["op": "blocks", "url": url.absoluteString, "topLevel": topLevel, "ads": ads]) as? Bool) ?? false
  }
  /// WebKit rules for a level; pages on `exceptions` (sites with Shields down) are exempt.
  public static func webKitRules(ads: Bool = true, exceptions: [String] = [], custom: [String] = []) throws -> String {
    let rules = try RustCore.request(["op": "webKitRules", "ads": ads, "exceptions": exceptions, "custom": custom])
    return String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
  }
  /// The address without click and campaign identifiers, or nil when it has none.
  public static func strippingTracking(_ url: URL) -> URL? {
    (try? RustCore.request(["op": "stripTracking", "url": url.absoluteString]) as? String).flatMap(URL.init(string:))
  }
  /// Domains from filter-list text: plain domains, hosts-file lines and `||domain^` rules.
  public static func parseRules(_ text: String) -> [String] {
    (try? RustCore.request(["op": "parseBlockRules", "value": text]) as? [String]) ?? []
  }
  /// The site key used for per-site settings: the host without "www.".
  public static func site(_ url: URL?) -> String? {
    guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
  /// Whether a page's host is one of the sites whose Shields are down.
  public static func isException(_ host: String?, in exceptions: [String]) -> Bool {
    guard let host = host?.lowercased(), !host.isEmpty else { return false }
    let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    return exceptions.contains { site == $0 || site.hasSuffix("." + $0) }
  }
}
