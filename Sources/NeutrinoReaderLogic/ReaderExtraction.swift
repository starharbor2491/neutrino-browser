// SPDX-License-Identifier: MPL-2.0
import Foundation
import NeutrinoCore

/// The isolated worker delegates XML validation and article extraction to Rust.
public enum ReaderExtraction {
    public static func extract(_ html: String) throws -> String {
        _ = try ReaderRequest(html: html)
        guard let text = try RustCore.request(["op": "reader", "html": html]) as? String else {
            throw ValidationError("Reader returned an invalid response.")
        }
        return try ReaderResponse(text: text).validatedText()
    }
}
