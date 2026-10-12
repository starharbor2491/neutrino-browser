// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum ContentBlocking {
  public static let domains = (try? RustCore.request(["op": "blockingDomains"]) as? [String]) ?? []
  public static func blocks(_ url: URL, topLevel: Bool = false) -> Bool {
    (try? RustCore.request(["op": "blocks", "url": url.absoluteString, "topLevel": topLevel]) as? Bool) ?? false
  }
  public static func webKitRules() throws -> String {
    let rules = try RustCore.request(["op": "webKitRules"])
    return String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
  }
}
