// SPDX-License-Identifier: MPL-2.0
import Foundation
public enum BoundedImportFile {
    public enum Kind: String, Sendable {case bookmarks, setup, module}
    public static func read(_ url:URL,maximumBytes:Int,kind:Kind) throws -> Data {
        guard let encoded=try RustCore.policy(["op":"boundedImport","path":url.isFileURL ? url.path : "","maximumBytes":maximumBytes,"kind":kind.rawValue]) as? String,
              let bytes=Data(base64Encoded:encoded) else {throw ValidationError("The selected file could not be read.")}
        return bytes
    }
}
