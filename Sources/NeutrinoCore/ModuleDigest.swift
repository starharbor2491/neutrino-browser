// SPDX-License-Identifier: MPL-2.0
import Foundation
import NeutrinoRust

/// Package integrity is portable Rust; the adapter lends bytes for this call.
public enum ModuleDigest {
    public static func sha256(_ data: Data) -> String {
        data.withUnsafeBytes { bytes in
            guard let hash=neutrino_sha256(bytes.bindMemory(to:UInt8.self).baseAddress,bytes.count) else {return ""}
            defer {neutrino_string_free(hash)}
            return String(cString:hash)
        }
    }
}
