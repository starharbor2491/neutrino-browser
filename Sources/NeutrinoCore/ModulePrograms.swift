// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Values crossing the constrained module interface. There are no handles, URLs,
/// callbacks, filesystem operations, or evaluation of JavaScript in this runtime.
public indirect enum ModuleValue: Codable, Equatable, Sendable {
    case string(String), bool(Bool), integer(Int), object([String: ModuleValue]), array([ModuleValue]), null
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Int.self) { self = .integer(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([String: ModuleValue].self) { self = .object(v) }
        else { self = .array(try value.decode([ModuleValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var integer: Int? { if case .integer(let value) = self { value } else { nil } }
    public var object: [String: ModuleValue]? { if case .object(let value) = self { value } else { nil } }
    public var array: [ModuleValue]? { if case .array(let value) = self { value } else { nil } }
    public func validate(depth: Int = 0) throws {
        _ = try RustCore.request(["op":"moduleValue","value":RustCore.encoded(self),"depth":depth])
    }
}

public struct ModuleExpression: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case literal, input, prefix, equal, choose, object }
    public var op: Operation
    public var value: ModuleValue?
    public var key: String?
    public var limit: Int?
    public var arguments: [ModuleExpression]?
    public var fields: [String: ModuleExpression]?
    public init(op: Operation, value: ModuleValue? = nil, key: String? = nil, limit: Int? = nil,
                arguments: [ModuleExpression]? = nil, fields: [String: ModuleExpression]? = nil) {
        self.op = op; self.value = value; self.key = key; self.limit = limit; self.arguments = arguments; self.fields = fields
    }
}

/// Small, terminating expression programs supply feature behavior. Neutrino only
/// applies validated output through native presentation and browser services.
public struct ModuleProgram: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var entrypoints: [String: ModuleExpression]
    public init(entrypoints: [String: ModuleExpression]) { formatVersion = 1; self.entrypoints = entrypoints }
    public static func validKey(_ key: String) -> Bool {
        (try? RustCore.request(["op":"moduleKey","value":key]) as? Bool) ?? false
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 128 * 1024 else { throw ValidationError("Behavior programs exceed 128 KB.") }
        try ModuleJSONBounds.validate(data)
        let program = try JSONDecoder().decode(Self.self, from: data)
        try program.validate(); return program
    }
    public func validate() throws {
        _ = try RustCore.request(["op":"validateProgram","program":RustCore.encoded(self)])
    }
    public func validate(capability: ModuleCapability) throws {
        _ = try RustCore.request(["op":"validateProgram","program":RustCore.encoded(self),"capability":capability.rawValue])
    }
    public func run(_ event: String, input: [String: ModuleValue]) throws -> [String: ModuleValue] {
        let output = try RustCore.request(["op":"runProgram","program":RustCore.encoded(self),"event":event,"input":RustCore.encoded(input)])
        return try JSONDecoder().decode([String:ModuleValue].self,from:JSONSerialization.data(withJSONObject:output))
    }
}

public struct ModuleSetting: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case toggle, choice, text, integer }
    public var id: String
    public var title: String
    public var kind: Kind
    public var defaultValue: ModuleValue
    public var choices: [String]?
    public func validate() throws {
        _ = try RustCore.request(["op":"validateSetting","setting":RustCore.encoded(self),"value":RustCore.encoded(defaultValue)])
    }
    public func validate(value: ModuleValue) throws {
        _ = try RustCore.request(["op":"validateSetting","setting":RustCore.encoded(self),"value":RustCore.encoded(value)])
    }
}

public enum NativeModuleAction: String, Codable, CaseIterable, Sendable {
    case newTab, bookmarks, history, downloads, modules, customize, settings, recovery
}
public struct ModuleMenuItem: Codable, Equatable, Sendable { public var title: String; public var action: NativeModuleAction }
public struct ModuleDefinition: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var treeTabs: Bool?
    public var theme: Theme?
    public var layout: BrowserLayout?
    public var icons: [String: String]?
    public var svgIcons: [String: String]?
    public var menu: [ModuleMenuItem]?
    public var widgetTitle: String?
    public var widgetBody: String?
    public static func decode(_ data: Data, capability: ModuleCapability) throws -> Self {
        guard data.count <= 128 * 1024 else { throw ValidationError("Declarative packages exceed 128 KB.") }
        try ModuleJSONBounds.validate(data)
        let definition = try JSONDecoder().decode(Self.self, from: data)
        try definition.validate(capability: capability); return definition
    }
    public func validate(capability: ModuleCapability) throws {
        _ = try RustCore.request(["op":"validateDefinition","definition":RustCore.encoded(self),"capability":capability.rawValue])
    }
}

/// Community catalogs carry only bounded data/programs, never downloaded native
/// executables. Claimed publishers are labels, not a verified signing identity.
public struct DeclarativeModulePackage: Codable, Equatable, Sendable {
    public var manifest: ModuleManifest
    public var program: ModuleProgram?
    public var definition: ModuleDefinition?
    public init(manifest: ModuleManifest, program: ModuleProgram? = nil, definition: ModuleDefinition? = nil) {
        self.manifest = manifest; self.program = program; self.definition = definition
    }
    public func payload() throws -> Data {
        guard let result=try RustCore.request(["op":"communityPayload","package":RustCore.encoded(self)]) as? [String:Any] else {throw ValidationError("Invalid community package.")}
        if let error=result["error"] as? String {throw ValidationError(error)}
        guard let payload=result["result"] else {throw ValidationError("Missing module payload.")}
        return try JSONSerialization.data(withJSONObject:payload,options:.sortedKeys)
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 192 * 1024 else { throw ValidationError("Local packages exceed 192 KB.") }
        try ModuleJSONBounds.validate(data)
        let package = try JSONDecoder().decode(Self.self, from: data); _ = try package.payload(); return package
    }
}
public struct DeclarativeModuleCatalog: Codable, Sendable {
    public var formatVersion: Int
    public var name: String
    public var packages: [DeclarativeModulePackage]
    public var sourceURL: URL?
    public init(formatVersion: Int = 1, name: String, packages: [DeclarativeModulePackage], sourceURL: URL? = nil) {
        self.formatVersion = formatVersion; self.name = name; self.packages = packages; self.sourceURL = sourceURL
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2 * 1024 * 1024 else { throw ValidationError("Catalogs exceed 2 MB.") }
        try ModuleJSONBounds.validate(data)
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard let result=try RustCore.request(["op":"validateCommunityCatalog","catalog":RustCore.encoded(catalog)]) as? [String:Any] else {throw ValidationError("Invalid community catalog.")}
        if let error=result["error"] as? String {throw ValidationError(error)}
        return catalog
    }
}

/// Bound nesting before recursive Codable decoding can allocate or recurse.
public enum ModuleJSONBounds {
    public static func validate(_ data: Data) throws {
        guard let json = String(data:data,encoding:.utf8) else { throw ValidationError("Module JSON is not valid UTF-8.") }
        _ = try RustCore.request(["op":"moduleJSONBounds","json":json])
    }
}
