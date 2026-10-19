// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum ModuleCapability: String, Codable, CaseIterable, Sendable {
    /// `feature` is a built-in browser feature the host implements; its module only turns it on or off.
    case resourceMonitor, notes, reader, screenshot, focusMode, tabSystem, theme, layout, icons, menu, startWidget, feature
    public var permission: String? {
        switch self {
        case .resourceMonitor: "Read system CPU and memory statistics. No browsing data is read."
        case .reader: "Read the current page when you choose Reader."
        case .screenshot: "Capture the current page when you choose Save screenshot."
        case .notes, .focusMode, .tabSystem, .theme, .layout, .icons, .menu, .startWidget, .feature: nil
        }
    }
    public var isExclusive: Bool { [.resourceMonitor, .notes, .screenshot, .focusMode, .tabSystem, .theme, .layout, .icons, .menu].contains(self) }
}
public enum ModuleRuntime: String, Codable, Sendable {
    case nativeResourceWorker, nativeReaderWorker, behaviorProgram, declarative
    public var isNative: Bool { self == .nativeResourceWorker || self == .nativeReaderWorker }
}
public struct ModuleManifest: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: Int
    public var summary: String
    public var publisher: String
    public var source: URL
    public var capability: ModuleCapability
    public var dependencies: [String]
    public var defaultInstalled: Bool
    public var runtime: ModuleRuntime?
    public var settings: [ModuleSetting]?
    public var minimumHostVersion: Int?
    public var dependencyVersions: [String: Int]?
    public init(id: String, name: String, version: Int = 1, summary: String, publisher: String = "Neutrino",
                source: URL = URL(string: "https://github.com/starharbor2491/neutrino-browser")!,
                capability: ModuleCapability, dependencies: [String] = [], defaultInstalled: Bool = true, runtime: ModuleRuntime? = nil, settings: [ModuleSetting]? = nil, minimumHostVersion: Int? = nil, dependencyVersions: [String: Int]? = nil) {
        self.id = id; self.name = name; self.version = version; self.summary = summary
        self.publisher = publisher; self.source = source; self.capability = capability
        self.dependencies = dependencies; self.defaultInstalled = defaultInstalled
        self.runtime = runtime; self.settings = settings; self.minimumHostVersion = minimumHostVersion
        self.dependencyVersions = dependencyVersions
    }
    public func validate() throws {
        _ = try RustCore.request(["op":"validateManifest","manifest":RustCore.encoded(self)])
    }
    public static func validID(_ id: String) -> Bool {
        (try? RustCore.request(["op":"moduleID","value":id]) as? Bool) ?? false
    }
    public static func decode(_ data: Data) throws -> ModuleManifest {
        guard data.count <= 32 * 1024 else { throw ValidationError("Module manifest exceeds 32 KB.") }
        try ModuleJSONBounds.validate(data)
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        try manifest.validate()
        return manifest
    }
}
public struct InstalledModule: Identifiable, Codable, Equatable, Sendable {
    public let manifest: ModuleManifest
    public var enabled: Bool
    public var id: String { manifest.id }
    public let diskBytes: Int
    public let payloadSHA256: String?
}
/// Every modern package stores its native code, behavior program, or declarative definition.
/// Execution trust is checked by the application against its bundled first-party worker bytes.
/// A typed macOS interoperability adapter. Rust owns storage and module policy.
public struct ModulePresentation: Codable, Sendable {
    public var settings: [String:[String:ModuleValue]]
    public var definitions: [String:ModuleDefinition]
    public var errors: [String:String]
    public init(settings: [String:[String:ModuleValue]] = [:], definitions: [String:ModuleDefinition] = [:], errors: [String:String] = [:]) {
        self.settings = settings; self.definitions = definitions; self.errors = errors
    }
}
public struct ModuleRepository: Sendable {
    public let root: URL
    public init(root: URL) throws { self.root = root; _ = try request("initialize") }
    private func request(_ action: String, _ fields: [String:Any] = [:]) throws -> Any {
        var input = fields; input["op"] = "moduleRepository"; input["action"] = action; input["root"] = root.path
        guard let result = try RustCore.request(input) as? [String:Any] else { throw ValidationError("Invalid module repository response.") }
        if let error = result["error"] as? String { throw ValidationError(error) }
        return result["result"] ?? NSNull()
    }
    private func decode<T:Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value,options:.fragmentsAllowed))
    }
    public func installed() throws -> [InstalledModule] { try decode([InstalledModule].self,request("installed")) }
    public func presentation() throws -> ModulePresentation { try decode(ModulePresentation.self,request("presentation")) }
    public func installationPlan(for id: String, catalog: [ModuleManifest], includeInstalled: Bool = false) throws -> [ModuleManifest] {
        try decode([ModuleManifest].self,request("plan",["id":id,"catalog":RustCore.encoded(catalog),"includeInstalled":includeInstalled]))
    }
    public func requirementsPlan(for ids: [String], catalog: [ModuleManifest], replacingRootProviders: Bool, preparingActivation: Bool) throws -> [ModuleManifest] {
        try decode([ModuleManifest].self, request("requirements",["ids":ids,"catalog":RustCore.encoded(catalog),"replacingRootProviders":replacingRootProviders,"preparingActivation":preparingActivation]))
    }
    public func withAtomicChanges<T>(for ids: [String], _ operation: () throws -> T) throws -> T {
        guard !ids.isEmpty else { return try operation() }
        _ = try request("begin",["ids":ids])
        do { let value = try operation(); _ = try request("commit"); return value }
        catch { _ = try request("rollback"); throw error }
    }
    public func install(_ manifest: ModuleManifest, enabled: Bool? = nil, payload: Data? = nil) throws {
        var fields:[String:Any] = ["manifest":try RustCore.encoded(manifest)]
        if let enabled { fields["enabled"] = enabled }
        if let payload { fields["payload"] = payload.base64EncodedString() }
        _ = try request("install",fields)
    }
    public func setEnabled(_ id: String, _ enabled: Bool) throws { _ = try request("setEnabled",["id":id,"enabled":enabled]) }
    public func replaceResourceProvider(with id: String) throws { try replaceProvider(role:.resourceMonitor,with:id) }
    public func replaceProvider(role: ModuleCapability, with id: String) throws { _ = try request("replace",["id":id,"role":role.rawValue]) }
    public func dataPayload(for id: String, runtime: ModuleRuntime, requireEnabled: Bool = true) throws -> Data {
        guard let encoded = try request("payload",["id":id,"runtime":runtime.rawValue,"requireEnabled":requireEnabled]) as? String,
              let bytes = Data(base64Encoded:encoded) else { throw ValidationError("Invalid module payload response.") }
        return bytes
    }
    public func behaviorProgram(for id: String, requireEnabled: Bool = true) throws -> ModuleProgram {
        let program = try ModuleProgram.decode(dataPayload(for:id,runtime:.behaviorProgram,requireEnabled:requireEnabled))
        guard let module = try installed().first(where:{$0.id==id}) else { throw ValidationError("This module is not installed.") }
        try program.validate(capability:module.manifest.capability); return program
    }
    public func definition(for id: String, requireEnabled: Bool = true) throws -> ModuleDefinition {
        guard let manifest = try installed().first(where:{$0.id==id})?.manifest else { throw ValidationError("This module is not installed.") }
        return try ModuleDefinition.decode(dataPayload(for:id,runtime:.declarative,requireEnabled:requireEnabled),capability:manifest.capability)
    }
    public func settings(for id: String) throws -> [String:ModuleValue] { try decode([String:ModuleValue].self,request("settings",["id":id])) }
    public func setSetting(_ key: String, value: ModuleValue, for id: String) throws { _ = try request("setSetting",["id":id,"key":key,"value":RustCore.encoded(value)]) }
    public func deleteSettings(for id: String) throws { _ = try request("deleteSettings",["id":id]) }
    public func communityCatalogs() throws -> [DeclarativeModuleCatalog] { try decode([DeclarativeModuleCatalog].self,request("catalogs")) }
    public func addCommunityCatalog(_ catalog: DeclarativeModuleCatalog, reservedIDs: Set<String>, replaceExisting: Bool = false) throws {
        _ = try DeclarativeModuleCatalog.decode(JSONEncoder().encode(catalog))
        _ = try request("addCatalog",["catalog":RustCore.encoded(catalog),"reservedIDs":Array(reservedIDs),"replaceExisting":replaceExisting])
    }
    public func removeCommunityCatalog(named name: String) throws { _ = try request("removeCatalog",["name":name]) }
    public func workerURL(for id: String, requireEnabled: Bool = true) throws -> URL {
        guard let path = try request("worker",["id":id,"requireEnabled":requireEnabled]) as? String else { throw ValidationError("Invalid worker path.") }
        return URL(fileURLWithPath:path)
    }
    public func uninstall(_ id: String) throws { _ = try request("uninstall",["id":id]) }
    public func disableAll() throws { _ = try request("disableAll") }
    public func seedDefaults(_ catalog: [ModuleManifest], payloads: [String:Data] = [:]) throws {
        guard try request("seeded") as? Bool != true else { return }
        for manifest in catalog where manifest.defaultInstalled {
            for item in try installationPlan(for:manifest.id,catalog:catalog) { try install(item,payload:payloads[item.id]) }
        }
        _ = try request("markSeeded")
    }
}
