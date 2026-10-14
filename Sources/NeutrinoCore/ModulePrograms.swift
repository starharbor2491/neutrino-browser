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
        guard formatVersion == 1 else { throw ValidationError("This declarative module is incompatible with Neutrino.") }
        let populated = [treeTabs != nil, theme != nil, layout != nil, icons != nil || svgIcons != nil, menu != nil, widgetTitle != nil || widgetBody != nil].filter { $0 }.count
        guard populated == 1 else { throw ValidationError("A declarative package must define exactly one role.") }
        switch capability {
        case .tabSystem: guard treeTabs != nil else { throw ValidationError("A tab system must choose its tab presentation.") }
        case .theme:
            guard let theme else { throw ValidationError("Invalid theme values.") }
            guard (theme.surfaceHex == nil) == (theme.textHex == nil) else { throw ValidationError("Custom theme surface and text colors must be supplied together.") }
            var normalized = theme; normalized.normalize()
            guard normalized == theme else { throw ValidationError("Theme values exceed Neutrino's supported ranges.") }
            if let surface = theme.surfaceHex, let text = theme.textHex,
               let a = InterfaceColor(hex: surface), let b = InterfaceColor(hex: text) {
                guard a.contrastRatio(against: b) >= 4.5 else { throw ValidationError("Theme text must meet the 4.5:1 contrast threshold against its surface.") }
            }
        case .layout:
            guard let layout else { throw ValidationError("Invalid layout values.") }
            var normalized = layout; normalized.normalize()
            guard normalized == layout else { throw ValidationError("Layout values exceed Neutrino's supported ranges.") }
        case .icons:
            if let svgIcons {
                _ = try RustCore.request(["op":"validateSVGIcons","icons":svgIcons])
                guard icons == nil else {throw ValidationError("Choose SVG paths or native symbol names, not both.")}
                return
            }
            let supported = Set(ToolbarCommand.allCases.map(\.rawValue)).union(["bookmarks", "history", "notes", "resources"])
            guard let icons, !icons.isEmpty, icons.count <= 32, Set(icons.keys).isSubset(of: supported),
                  icons.values.allSatisfy({ !$0.isEmpty && $0.count <= 80 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") } }) else { throw ValidationError("Invalid native symbol names.") }
        case .menu:
            guard let menu, !menu.isEmpty, menu.count <= 16, menu.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 80 }) else { throw ValidationError("Invalid menu items.") }
        case .startWidget:
            guard let widgetTitle, let widgetBody, !widgetTitle.isEmpty, widgetTitle.count <= 100, widgetBody.count <= 1000 else { throw ValidationError("Invalid start-page widget.") }
        default: throw ValidationError("This role cannot use a declarative package.")
        }
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
        try manifest.validate()
        let payload: Data
        switch manifest.runtime {
        case .behaviorProgram:
            guard let program, definition == nil else { throw ValidationError("A behavior package needs its program.") }
            try program.validate(capability: manifest.capability); payload = try JSONEncoder().encode(program)
        case .declarative:
            guard let definition, program == nil else { throw ValidationError("A declarative package needs its definition.") }
            try definition.validate(capability: manifest.capability); payload = try JSONEncoder().encode(definition)
        default: throw ValidationError("Community packages cannot contain native code or descriptor-only features.")
        }
        guard payload.count <= 128 * 1024 else { throw ValidationError("A module's payload exceeds 128 KB.") }
        return payload
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
        guard catalog.formatVersion == 1, !catalog.name.isEmpty, catalog.name.count <= 100, catalog.packages.count <= 64,
              Set(catalog.packages.map { $0.manifest.id }).count == catalog.packages.count else { throw ValidationError("Invalid community catalog.") }
        if let url = catalog.sourceURL {
            guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw ValidationError("A catalog source must be an HTTPS URL without credentials.") }
        }
        for package in catalog.packages { _ = try package.payload() }
        return catalog
    }
}

/// Bound nesting before recursive Codable decoding can allocate or recurse.
public enum ModuleJSONBounds {
    public static func validate(_ data: Data) throws {
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 64 else { throw ValidationError("Module JSON exceeds the nesting limit.") }
            } else if byte == 125 || byte == 93 {
                depth -= 1
                guard depth >= 0 else { throw ValidationError("Module JSON is malformed.") }
            }
        }
        guard depth == 0, !quoted else { throw ValidationError("Module JSON is incomplete.") }
    }
}
