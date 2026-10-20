// SPDX-License-Identifier: MPL-2.0
import AppKit
import Foundation
import NeutrinoCore

struct ModuleApprovalSnapshot: Equatable {
    let rootIDs: [String]
    let requirements: [ModuleManifest]
    let repositoryRoot: URL
    let installed: [InstalledModule]
    let catalogPayloadSHA256: [String: String]
}

@MainActor
extension AppState {
    func requireModuleMutationAllowed() throws {
        guard !finalQuitDataFrozen else { throw ValidationError("Neutrino is saving data before quitting. Try again if the quit is canceled.") }
        guard !stoppingModuleWorkers else { throw ValidationError("Another module operation is stopping its workers. Try again when it finishes.") }
    }
    /// Foundation's synchronous process wait services the main run loop. Keep
    /// other package operations out of that wait, before resuming this mutation.
    func stopWorkersForModuleMutation(moduleID: String? = nil, stoppingReader: Bool = true) throws {
        try requireModuleMutationAllowed()
        stoppingModuleWorkers = true
        do {
            defer { stoppingModuleWorkers = false }
            ResourceWorker.stopAll(moduleID: moduleID)
            if stoppingReader { cancelReaderRequests(moduleID: moduleID) }
        }
        try requireModuleMutationAllowed()
    }
    func captureModuleApproval(_ requirements: [ModuleManifest], rootIDs: [String]) throws -> ModuleApprovalSnapshot {
        guard let repository, requirements.count <= 128, Set(requirements.map(\.id)).count == requirements.count,
              rootIDs.count <= 64 else { throw ValidationError("This module operation exceeds its package limit.") }
        var hashes: [String: String] = [:]
        for manifest in requirements {
            if let payload = modulePayloads[manifest.id] { hashes[manifest.id] = ModuleDigest.sha256(payload) }
        }
        return ModuleApprovalSnapshot(rootIDs: rootIDs, requirements: requirements, repositoryRoot: repository.root,
                                      installed: try repository.installed(), catalogPayloadSHA256: hashes)
    }
    func validateModuleApproval(_ approval: ModuleApprovalSnapshot, requirements: [ModuleManifest]) throws {
        try requireModuleMutationAllowed()
        guard try captureModuleApproval(requirements, rootIDs: approval.rootIDs) == approval else {
            throw ValidationError("The packages or active providers changed while the approval was open. Review the updated modules and permissions before trying again.")
        }
    }
    /// Application updates can change a worker's code signature without changing
    /// its manifest version. Refresh only already installed official native roles;
    /// removed packages and user activation choices survive the application update.
    func refreshBundledNativePackages() throws {
        try requireModuleMutationAllowed()
        guard let repository else { return }
        for current in installedModules where current.manifest.runtime?.isNative == true {
            guard bundledModuleIDs.contains(current.id), let factory = catalog.first(where: { $0.id == current.id }),
                  let trusted = modulePayloads[current.id], current.manifest.version <= factory.version,
                  current.manifest.runtime == factory.runtime, current.manifest.capability == factory.capability,
                  current.manifest.publisher == factory.publisher, current.manifest.source == factory.source,
                  current.manifest.dependencies == factory.dependencies,
                  current.manifest.dependencyVersions == factory.dependencyVersions,
                  current.manifest.settings == factory.settings else { continue }
            let existing: Data?
            if let url = try? repository.workerURL(for: current.id, requireEnabled: false) {
                existing = try? readModuleFile(url, limit: 8 * 1024 * 1024)
            } else { existing = nil }
            if current.manifest != factory || existing != trusted {
                try stopWorkersForModuleMutation(moduleID: current.id)
                try repository.install(factory, enabled: current.enabled, payload: trusted)
            }
        }
        installedModules = try repository.installed()
    }
    func behaviorResult(_ capability: ModuleCapability, event: String, input: [String: ModuleValue] = [:]) throws -> [String: ModuleValue] {
        guard !terminating, let repository,
              let module = installedModules.first(where: { $0.enabled && $0.manifest.capability == capability && $0.manifest.runtime == .behaviorProgram }) else {
            throw ValidationError("Install and enable this feature's behavior package in Modules.")
        }
        let settings = try repository.settings(for: module.id)
        let values = settings.merging(input) { _, supplied in supplied }
        return try repository.behaviorProgram(for: module.id).run(event, input: values)
    }
    func declarativeDefinition(_ capability: ModuleCapability) -> ModuleDefinition? {
        guard let module = installedModules.first(where: {
            $0.enabled && $0.manifest.capability == capability && $0.manifest.runtime == .declarative
        }) else { return nil }
        return modulePresentation.definitions[module.id]
    }
    var modulePresentation: ModulePresentation {
        if let modulePresentationCache { return modulePresentationCache }
        let projection: ModulePresentation
        do { projection = try repository?.presentation() ?? ModulePresentation() }
        catch { projection = ModulePresentation(errors:["*":error.localizedDescription]) }
        modulePresentationCache = projection
        return projection
    }
    var startWidgets: [ModuleDefinition] {
        let definitions = modulePresentation.definitions
        return installedModules.filter { $0.enabled && $0.manifest.capability == .startWidget && $0.manifest.runtime == .declarative }
            .compactMap { definitions[$0.id] }
    }
    func requestedFocusPresentation() throws -> (moduleID: String, hiddenComponents: Set<String>) {
        let output = try behaviorResult(.focusMode, event: "enter")
        guard let module = installedModules.first(where: { $0.enabled && $0.manifest.capability == .focusMode && $0.manifest.runtime == .behaviorProgram }) else { throw ValidationError("Enable a Focus Mode provider first.") }
        let names = try RustCore.decode([String].self,from:RustCore.request(["op":"focusPresentation","output":RustCore.encoded(output)]))
        return (module.id, Set(names))
    }
    private struct CaptureSpecification: Decodable { let filename: String; let visibleOnly: Bool }
    func pageCaptureSpecification() throws -> (filename: String, visibleOnly: Bool) {
        let output = try behaviorResult(.screenshot, event: "prepare")
        let result = try RustCore.decode(CaptureSpecification.self,from:RustCore.request(["op":"captureSpecification","output":RustCore.encoded(output)]))
        return (result.filename,result.visibleOnly)
    }
    private struct NoteMutation: Decodable { let note: Note?; let remove: Bool }
    private func mutateModuleNote(action: String, profileID: UUID, output: [String:ModuleValue], id: UUID? = nil, field: String = "") throws -> UUID? {
        let index = library.notes.firstIndex { $0.id == id && $0.profileID == profileID }
        var request: [String:Any] = ["op":"moduleNote","action":action,"profileID":profileID.uuidString,"profiles":library.profiles.map { $0.id.uuidString },"output":try RustCore.encoded(output),"field":field]
        if let index { request["value"] = try RustCore.encoded(library.notes[index]) }
        if let id { request["id"] = id.uuidString }
        let result = try RustCore.decode(NoteMutation.self,from:RustCore.request(request))
        if result.remove { library.notes.removeAll { $0.id == id && $0.profileID == profileID } }
        else if let note = result.note {
            if let index { library.notes[index] = note }
            else { library.notes.append(note) }
            return note.id
        }
        return nil
    }
    func createModuleNote(profileID: UUID) throws -> UUID {
        let output = try behaviorResult(.notes,event:"create")
        guard let id = try mutateModuleNote(action:"create",profileID:profileID,output:output) else { throw ValidationError("The Notes package did not create a note.") }
        return id
    }
    func updateModuleNote(id: UUID, profileID: UUID, field: String, value: String) throws {
        let output = try behaviorResult(.notes,event:"update",input:["field":.string(field),"value":.string(value)])
        _ = try mutateModuleNote(action:"update",profileID:profileID,output:output,id:id,field:field)
    }
    func deleteModuleNote(id: UUID, profileID: UUID) throws {
        _ = try mutateModuleNote(action:"delete",profileID:profileID,output:behaviorResult(.notes,event:"delete"),id:id)
    }
    func moduleSetting(_ schema: ModuleSetting, moduleID: String) -> ModuleValue {
        let values = modulePresentation.settings[moduleID] ?? [:]
        return values[schema.id] ?? schema.defaultValue
    }
    func setModuleSetting(_ schema: ModuleSetting, value: ModuleValue, moduleID: String) {
        perform {
            try requireModuleMutationAllowed()
            guard let repository else { throw ValidationError("Repair module storage first.") }
            try repository.setSetting(schema.id, value: value, for: moduleID)
            modulePresentationCache = nil
            // Preferences are separate data, so publishing an edit must not
            // invalidate running workers or unrelated in-flight page actions.
            objectWillChange.send()
        }
    }
    func validateModulePayload(_ module: InstalledModule, requireEnabled: Bool) throws {
        guard let repository else { throw ValidationError("Repair module storage first.") }
        switch module.manifest.runtime {
        case .nativeReaderWorker, .nativeResourceWorker:
            _ = try validatedWorkerPackage(id: module.id, requireEnabled: requireEnabled)
        case .behaviorProgram: _ = try repository.behaviorProgram(for: module.id, requireEnabled: requireEnabled)
        case .declarative: _ = try repository.definition(for: module.id, requireEnabled: requireEnabled)
        case nil:
            // Built-in features are implemented by the host and carry no payload.
            guard module.manifest.capability == .feature, bundledModuleIDs.contains(module.id) else {
                throw ValidationError("This legacy descriptor no longer provides a feature. Update or replace it in Modules.")
            }
        }
    }
    func moduleManifestCandidate(_ id: String) -> ModuleManifest? {
        let available = catalog.first(where: { $0.id == id }), existing = installedModules.first(where: { $0.id == id })?.manifest
        if let existing, existing.version >= (available?.version ?? 0) { return existing }
        return available ?? existing
    }
    func validateModuleRequirements(for ids: [String], replacingRootProviders: Bool = true, preparingActivation: Bool = true, repairingIDs: Set<String> = []) throws -> [ModuleManifest] {
        guard let repository else { throw ValidationError("Repair module storage first.") }
        let result = try repository.requirementsPlan(for:ids,catalog:catalog,replacingRootProviders:replacingRootProviders,preparingActivation:preparingActivation)
        // macOS retains executable signature/first-party checks. Portable plan
        // selection, conflicts, dependencies and output validation live in Rust.
        for manifest in result {
            if !repairingIDs.contains(manifest.id), let existing = installedModules.first(where: { $0.id == manifest.id && $0.manifest == manifest }) {
                try validateModulePayload(existing, requireEnabled:false)
            } else if manifest.capability == .feature, manifest.runtime == nil, bundledModuleIDs.contains(manifest.id) {
                continue
            } else {
                guard let payload = modulePayloads[manifest.id] else { throw ValidationError("The catalog is missing \(manifest.name)'s package payload.") }
                if manifest.runtime == .behaviorProgram { try ModuleProgram.decode(payload).validate(capability:manifest.capability) }
                else if manifest.runtime == .declarative { _ = try ModuleDefinition.decode(payload,capability:manifest.capability) }
                else { guard manifest.runtime?.isNative == true, bundledModuleIDs.contains(manifest.id), !payload.isEmpty, payload.count <= 8 * 1024 * 1024 else { throw ValidationError("This native package is not a trusted bundled worker.") } }
            }
        }
        return result
    }
    func compatibleReinstallationManifest(for id: String) throws -> ModuleManifest {
        guard let current = installedModules.first(where: { $0.id == id }),
              let available = catalog.first(where: { $0.id == id && $0.runtime != nil }) else { throw ValidationError("This package has no available catalog source. Add or refresh its source catalog before reinstalling.") }
        if available.version > current.manifest.version {
            throw ValidationError("Choose Update to review the newer package and its dependencies before reinstalling it.")
        }
        guard available == current.manifest else { throw ValidationError("The catalog does not contain this installed version and definition. Refresh its source catalog before reinstalling. The installed package is kept.") }
        return available
    }
    /// All candidates start with their existing activation choice, and new
    /// packages stay disabled until the approved closure is ready to activate.
    func installApprovedModuleCode(_ requirements: [ModuleManifest], repairingIDs: Set<String> = []) throws {
        try requireModuleMutationAllowed()
        guard let repository else { throw ValidationError("Repair module storage first.") }
        // Capture the reviewed code and activation choices before any process
        // wait can service another main-run-loop callback.
        let candidates = requirements.filter { manifest in
            repairingIDs.contains(manifest.id) || !installedModules.contains(where: { $0.id == manifest.id && $0.manifest == manifest })
        }.map { manifest in
            (manifest: manifest, enabled: installedModules.first(where: { $0.id == manifest.id })?.enabled ?? false,
             payload: modulePayloads[manifest.id])
        }
        for candidate in candidates {
            try stopWorkersForModuleMutation(moduleID: candidate.manifest.id)
            try repository.install(candidate.manifest, enabled: candidate.enabled, payload: candidate.payload)
        }
        installedModules = try repository.installed()
    }
    func activateApprovedModuleRequirements(_ requirements: [ModuleManifest]) throws {
        try requireModuleMutationAllowed()
        guard let repository else { throw ValidationError("Repair module storage first.") }
        for manifest in requirements {
            guard let installed = installedModules.first(where: { $0.id == manifest.id && $0.manifest == manifest }) else { throw ValidationError("A required package did not install.") }
            if !installed.enabled {
                if manifest.capability.isExclusive {
                    if manifest.capability == .resourceMonitor { try replaceResourceProvider(with: manifest.id) }
                    else { try repository.replaceProvider(role: manifest.capability, with: manifest.id) }
                } else { try repository.setEnabled(manifest.id, true) }
                installedModules = try repository.installed()
            }
        }
    }
    func withAtomicModuleChanges<T>(for ids: [String], _ operation: () throws -> T) throws -> T {
        try requireModuleMutationAllowed()
        guard let repository else { throw ValidationError("Repair module storage first.") }
        if suspendingModuleContributions { return try operation() }
        let previous = installedModules
        moduleConfigurationBeforeMutation = nil
        suspendingModuleContributions = true
        defer { suspendingModuleContributions = false; moduleConfigurationBeforeMutation = nil; invalidateModuleExecution() }
        do {
            let result = try repository.withAtomicChanges(for: ids, operation)
            installedModules = try repository.installed()
            suspendingModuleContributions = false
            synchronizeModuleContributions(previous: previous)
            return result
        } catch {
            installedModules = (try? repository.installed()) ?? previous
            // A layout edit arriving while a worker was reaped belongs to its
            // editor. Roll back only configuration this transaction applied.
            if let configuration = moduleConfigurationBeforeMutation { applyConfiguration(configuration) }
            throw error
        }
    }
    func loadCommunityCatalogs() throws {
        guard let repository else { return }
        let communities = try repository.communityCatalogs()
        var manifests = catalog.filter { bundledModuleIDs.contains($0.id) }
        var payloads = modulePayloads.filter { bundledModuleIDs.contains($0.key) }
        var seen = bundledModuleIDs
        for community in communities {
            for package in community.packages {
                guard seen.insert(package.manifest.id).inserted else { throw ValidationError("A community catalog conflicts with another installed catalog.") }
                manifests.append(package.manifest); payloads[package.manifest.id] = try package.payload()
            }
        }
        communityCatalogNames = communities.map(\.name).sorted()
        modulePayloads = payloads
        catalog = manifests.sorted { $0.name < $1.name }
    }
    func importCatalog() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.message = "Choose a community catalog containing bounded declarative or behavior packages. Adding a catalog does not install its modules."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            try requireModuleMutationAllowed()
            guard let repository else { throw ValidationError("Repair module storage first.") }
            let catalog = try DeclarativeModuleCatalog.decode(readModuleFile(url, limit: 2 * 1024 * 1024))
            let replacing = try repository.communityCatalogs().contains { $0.name == catalog.name }
            try addCatalog(catalog, replaceExisting: replacing)
        }
    }
    func addCatalog(_ catalog: DeclarativeModuleCatalog, replaceExisting: Bool = false) throws {
        try requireModuleMutationAllowed()
        guard let repository else { throw ValidationError("Repair module storage first.") }
        let alert = NSAlert(); alert.messageText = replaceExisting ? "Refresh \(catalog.name)?" : "Add \(catalog.name)?"
        alert.informativeText = "\(catalog.packages.count) data packages will appear in Discover. Publishers are self-reported. No modules will be installed or granted permissions until you approve their installation."
        alert.addButton(withTitle: replaceExisting ? "Refresh catalog" : "Add catalog"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try requireModuleMutationAllowed()
        try repository.addCommunityCatalog(catalog, reservedIDs: bundledModuleIDs, replaceExisting: replaceExisting); try loadCommunityCatalogs()
    }
    func removeCatalog(named name: String) {
        let alert = NSAlert(); alert.messageText = "Remove \(name)?"
        alert.informativeText = "Its packages disappear from Discover and Updates. Already installed modules and their data are kept."
        alert.addButton(withTitle: "Remove catalog"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            try requireModuleMutationAllowed()
            try repository?.removeCommunityCatalog(named: name); try loadCommunityCatalogs()
            notice = "The catalog was removed. Already installed modules and their data are kept."
        }
    }
    func readModuleFile(_ url: URL, limit: Int) throws -> Data {
        try BoundedImportFile.read(url, maximumBytes: limit, kind: .module)
    }
    func presentTabReplacementBeforeRemoval(_ current: InstalledModule, removeAfterReplacement: Bool = true) {
        let dependents = installedModules.filter { $0.manifest.dependencies.contains(current.id) && (removeAfterReplacement || $0.enabled) }
        guard dependents.isEmpty else {
            notice = (removeAfterReplacement ? "Remove these dependent modules first: " : "Disable these dependent modules first: ") + dependents.map { $0.manifest.name }.joined(separator: ", ")
            return
        }
        let candidates = Set(catalog.map(\.id) + installedModules.map(\.id))
        let replacements = candidates.compactMap(moduleManifestCandidate).filter { $0.id != current.id && $0.capability == .tabSystem && $0.runtime == .declarative }.sorted { $0.name < $1.name }
        guard !replacements.isEmpty else { notice = "Install a compatible tab system before removing the active one. Your tabs are kept."; return }
        let alert = NSAlert(); alert.messageText = "Choose a replacement for \(current.manifest.name)"
        alert.informativeText = "Your open tabs, pinned tabs, tree relationships, and split panes are kept. The chosen replacement is validated before activation. " + (removeAfterReplacement ? "The current package is then removed." : "The current package stays installed and becomes inactive.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 28))
        popup.addItems(withTitles: replacements.map(\.name)); alert.accessoryView = popup
        alert.addButton(withTitle: removeAfterReplacement ? "Replace and uninstall" : "Replace"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, replacements.indices.contains(popup.indexOfSelectedItem) else { return }
        let replacement = replacements[popup.indexOfSelectedItem]
        perform {
            let requirements = try validateModuleRequirements(for: [replacement.id])
            let approval = try captureModuleApproval(requirements, rootIDs: [replacement.id])
            guard approveModules(requirements, activateRequirements: true, activationTitle: "Activate \(replacement.name)?") else { return }
            try replaceTabProviderApproved(currentID: current.id, replacementID: replacement.id, removeCurrent: removeAfterReplacement, approval: approval)
        }
    }
    func replaceTabProviderApproved(currentID: String, replacementID: String, removeCurrent: Bool, approval: ModuleApprovalSnapshot? = nil) throws {
        guard let repository, currentID != replacementID,
              let current = installedModules.first(where: { $0.id == currentID && $0.enabled && $0.manifest.capability == .tabSystem }),
              moduleManifestCandidate(replacementID)?.capability == .tabSystem else { throw ValidationError("Choose a compatible replacement for the active tab system.") }
        let dependents = installedModules.filter { $0.manifest.dependencies.contains(current.id) && (removeCurrent || $0.enabled) }
        guard dependents.isEmpty else { throw ValidationError("Resolve these dependent modules before replacing the tab system: " + dependents.map { $0.manifest.name }.joined(separator: ", ")) }
        let requirements = try validateModuleRequirements(for: [replacementID])
        if let approval { try validateModuleApproval(approval, requirements: requirements) }
        try withAtomicModuleChanges(for: Array(Set(requirements.map(\.id) + [currentID]))) {
            try installApprovedModule(replacementID)
            try repository.replaceProvider(role: .tabSystem, with: replacementID)
            if removeCurrent { try repository.uninstall(currentID) }
            installedModules = try repository.installed()
        }
    }
}
