// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Presentation data from a resource provider. No callbacks, file paths, or executable UI.
public struct ResourceMetric: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public var detail: String
    public var fraction: Double?
    public var samples: [Double]
    public init(_ name: String, value: String, detail: String = "", fraction: Double? = nil, samples: [Double] = []) {
        self.name = name; self.value = value; self.detail = detail; self.fraction = fraction; self.samples = samples
    }
}
public struct ResourceFrame: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String
    public var metrics: [ResourceMetric]
    public init(title: String, detail: String, metrics: [ResourceMetric]) {
        self.title = title; self.detail = detail; self.metrics = metrics
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 else { throw ValidationError("The resource worker returned too much data.") }
        let frame = try JSONDecoder().decode(Self.self, from: data)
        _ = try RustCore.policy(["op":"validateResourceFrame","value":RustCore.encoded(frame)])
        return frame
    }
}
