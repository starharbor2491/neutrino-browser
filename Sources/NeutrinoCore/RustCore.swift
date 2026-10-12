// SPDX-License-Identifier: MPL-2.0
import Foundation
import NeutrinoRust

/// Typed ownership boundary for portable Rust services. No website controls this ABI.
public enum RustCore {
    public static func request(_ request: [String: Any]) throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: request)
        guard data.count <= 64 * 1024 * 1024, let json = String(data: data, encoding: .utf8),
              let pointer = json.withCString({ neutrino_core_request($0) }) else {
            throw ValidationError("The browser request could not be encoded.")
        }
        defer { neutrino_string_free(pointer) }
        guard let response = try JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? [String: Any] else {
            throw ValidationError("The browser returned an invalid response.")
        }
        if let error = response["error"] as? String { throw ValidationError(error) }
        return response["value"] ?? NSNull()
    }
}
