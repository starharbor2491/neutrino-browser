// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A bounded starter list shipped with the app, requiring no subscription or
/// network download. Match host labels, never URL substrings or top-level pages.
public enum ContentBlocking {
  public static let domains = [
    "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
    "googletagmanager.com", "adnxs.com", "adsrvr.org", "criteo.com", "criteo.net",
    "scorecardresearch.com", "quantserve.com", "taboola.com", "outbrain.com", "hotjar.com",
    "hotjar.io", "clarity.ms", "facebook.net", "segment.io",
  ]
  public static func blocks(_ url: URL, topLevel: Bool = false) -> Bool {
    guard !topLevel, let host = url.host?.lowercased() else { return false }
    return domains.contains { host == $0 || host.hasSuffix("." + $0) }
  }
  public static func webKitRules() throws -> String {
    let rules: [[String: Any]] = domains.map { domain in
      [
        "trigger": [
          "url-filter": "^https?://([^/]+\\.)?" + NSRegularExpression.escapedPattern(for: domain)
            + "[/:]",
          "resource-type": ["image", "style-sheet", "script", "font", "raw", "media", "popup"],
        ], "action": ["type": "block"],
      ]
    }
    return String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
  }
}
