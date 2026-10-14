// SPDX-License-Identifier: MPL-2.0
import Foundation
import NeutrinoRust

/// Typed ownership boundary for portable Rust services. No website controls this ABI.
public enum RustCore {
    public static func encoded<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        try JSONDecoder().decode(type, from:JSONSerialization.data(withJSONObject:value, options:.fragmentsAllowed))
    }
    public static func transform<T: Codable>(_ value: T, operation: String) throws -> T {
        let encoder=JSONEncoder()
        // JSON has no NaN/Infinity. Preserve their invalidness as inert markers
        // so the Rust normalizer can replace them with finite defaults.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity:"Infinity",negativeInfinity:"-Infinity",nan:"NaN")
        let encoded = try JSONSerialization.jsonObject(with: encoder.encode(value))
        let transformed = try request(["op": operation, "value": encoded])
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: transformed))
    }
    public static func policy(_ request: [String:Any]) throws -> Any {
        guard let result=try self.request(request) as? [String:Any] else {throw ValidationError("The browser returned an invalid policy response.")}
        if let error=result["error"] as? String {throw ValidationError(error)}
        return result["result"] ?? NSNull()
    }
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
