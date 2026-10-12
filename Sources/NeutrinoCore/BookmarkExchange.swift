// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Rust owns HTML scanning, escaping, URL validation, bounds and deduplication.
public enum BookmarkExchange {
    public static func export(_ bookmarks: [Bookmark]) throws -> Data {
        let records = bookmarks.map { ["title":$0.title,"url":$0.url.absoluteString] }
        guard let html = try RustCore.request(["op":"exportBookmarks","bookmarks":records]) as? String else { throw ValidationError("The bookmarks could not be exported.") }
        return Data(html.utf8)
    }
    public static func parse(_ data: Data, profileID: UUID) throws -> [Bookmark] {
        guard data.count <= 10 * 1024 * 1024, let html=String(data:data,encoding:.utf8) else { throw ValidationError("Choose a UTF-8 bookmarks HTML file smaller than 10 MB.") }
        guard let records=try RustCore.request(["op":"parseBookmarks","html":html]) as? [[String:String]] else { throw ValidationError("The bookmarks could not be read.") }
        return records.compactMap { item in
            guard let source=item["url"], let url=URL(string:source) else { return nil }
            return Bookmark(profileID:profileID,title:item["title"] ?? "Bookmark",url:url)
        }
    }
}
