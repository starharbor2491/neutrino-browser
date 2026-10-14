// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct RemovedProfileContents: Codable, Sendable {
    public let profile: Profile
    public let bookmarks: [Bookmark]
    public let history: [HistoryEntry]
    public let notes: [Note]
    public let sessions: [WindowSession]
    public let spaces: [BrowserSpace]
}
extension LibraryState {
    /// Website stores are erased separately; this durable tombstone makes interruption recoverable.
    public mutating func removeProfile(_ id: UUID, replacingWith replacement: UUID) throws -> RemovedProfileContents {
        guard let result=try RustCore.request(["op":"removeProfile","value":RustCore.encoded(self),"id":id.uuidString,"replacement":replacement.uuidString]) as? [String:Any],
          let updated=result["value"],let removed=result["removed"] else {throw ValidationError("The profile could not be removed.")}
        let state=try RustCore.decode(Self.self,from:updated)
        let contents=try RustCore.decode(RemovedProfileContents.self,from:removed)
        self=state;return contents
    }
    /// Restores this profile without discarding concurrent edits elsewhere.
    public mutating func restoreProfile(_ contents: RemovedProfileContents) {
        if let value=try? RustCore.decode(Self.self,from:RustCore.request(["op":"restoreProfile","value":RustCore.encoded(self),"contents":RustCore.encoded(contents)])) {self=value}
    }
}
