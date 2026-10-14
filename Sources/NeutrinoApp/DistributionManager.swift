// SPDX-License-Identifier: MPL-2.0
import AppKit
import CryptoKit
import Darwin
import NeutrinoCore
import NeutrinoDistribution
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DistributionManager: ObservableObject {
    static let shared = DistributionManager()
    static let chromiumRemovalNotice = "Blink tabs reopen in WebKit at their saved HTTP(S) addresses. Internal pages become blank tabs. Cookies, sign-ins, and unsaved work do not transfer between engines. Neutrino bookmarks, history, notes, Profiles, Spaces, archived tabs, modules, and setups are kept. Blink's saved website data remains on disk."
    @Published private(set) var available: [DistributionAsset] = []
    @Published private(set) var busy = false
    @Published private(set) var progress: Double?
    @Published private(set) var message: String?
    @Published private(set) var pending: DistributionRelease?
    private var candidate: URL?
    private var rejectedStage: URL?
    private var destination: URL?
    private var directory: URL?
    private var operation: Task<Void, Never>?
    private var cleanupOperation: Task<Void, Never>?
    private var terminationPending = false
    var canCancel: Bool { operation != nil }
    private var installerStarted = false
    private var installerProcess: Process?
    private var installerHelper: URL?
    private var generation = UUID()
    private var installOnQuit = false
    private var restartRequested = false
    private var sparkle: SparkleUpdates?
    var usesSparkle: Bool {sparkle != nil}
    var canUninstall: Bool { sparkle?.canUninstall ?? true }
    func acceptSparkle(build: String, epoch: String?) throws {
        guard let current, let build = Int(build), let epoch, let number = Int(epoch), let directory else {
            throw ValidationError("The update is missing its engine security version.")
        }
        _ = try RustCore.request(["op":"validateUpdatePolicy", "build":build,"currentBuild":current.build,"epoch":number,"floor":try securityFloor()])
        try JSONEncoder().encode(number).write(to:directory.appendingPathComponent("security-floor.json"),options:.atomic)
    }
    var isRestartRequested: Bool { restartRequested }
    @Published var automaticUpdates = UserDefaults.standard.object(forKey: "automaticAppUpdates") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticUpdates, forKey: "automaticAppUpdates")
            sparkle?.setAutomatic(automaticUpdates)
            if !restartRequested { installOnQuit = automaticUpdates && pending != nil && pending?.chromium == current?.chromium }
            if !automaticUpdates && automaticDownload { operation?.cancel() }
        }
    }
    private var initialization: Task<Void, Never>?
    private var automaticCheck: Task<Void, Never>?
    private var automaticDownload = false
    private var pendingCodeHash: String?
    @Published private(set) var pendingRecordInvalid = false
    private struct PendingInstall: Codable, Sendable {
        let candidate: URL
        let destination: URL
        let release: DistributionRelease
        let codeDirectoryHash: String?
    }
    @Published private(set) var publisherAvailable = false
    @Published private(set) var current: DistributionRelease?
    private var authority: ReleaseTrust.UpdateAuthority?
    func cancel() { operation?.cancel() }
    func cancelAndWaitForOperation() async {
        terminationPending = true
        initialization?.cancel()
        await initialization?.value
        initialization = nil
        automaticCheck?.cancel()
        await automaticCheck?.value
        automaticCheck = nil
        let active = operation
        active?.cancel()
        await active?.value
        await cleanupOperation?.value
    }
    func configure(dataDirectory: URL) {
        guard directory == nil else { return }
        directory = dataDirectory.resolvingSymlinksInPath().appendingPathComponent("Updates", isDirectory: true)
        current = try? ReleaseTrust.metadata(of: Bundle.main.bundleURL, requireCompatibleArchitecture: false)
        do {
            try FileManager.default.createDirectory(at: directory!, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard (try directory!.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
                  (try directory!.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw ValidationError("The update storage location must be a regular directory.")
            }
            if FileManager.default.fileExists(atPath: journalURL!.path) {
                message = "A previous installation was interrupted. Import a verified installer to repair it; your browser data is kept."
            }
        } catch { message = error.localizedDescription; directory = nil; return }
        let installed = Bundle.main.bundleURL
        initialization = Task {
            defer { self.initialization = nil }
            do {
                let authority = try await Self.background { try ReleaseTrust.updateAuthority(of: installed) }
                guard !Task.isCancelled, !self.terminationPending else { return }
                self.authority = authority
                if let updater = SparkleUpdates.make(automatic: self.automaticUpdates) {
                    self.sparkle = updater; self.publisherAvailable = true
                    self.message = "Sparkle checks GitHub for signed Neutrino updates, including Chromium. Your browsing data stays in place."
                    return
                }
                do { try await self.restorePending(authority: authority) }
                catch { self.message = error.localizedDescription; self.pendingRecordInvalid = true }
                guard !Task.isCancelled, !self.terminationPending else { return }
                self.publisherAvailable = true
                self.scheduleAutomaticChecks()
            } catch { if self.message == nil { self.message = error.localizedDescription } }
        }
    }
    private func scheduleAutomaticChecks() {
        guard automaticCheck == nil, ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_DATA"] == nil,
              !CommandLine.arguments.contains(where: { $0.contains("xctest") }) else { return }
        automaticCheck = Task {
            do {
                try await Task.sleep(for: .seconds(20))
                while !Task.isCancelled {
                    if self.automaticUpdates, let directory = self.directory {
                        self.checkForUpdates(dataDirectory: directory.deletingLastPathComponent(), automatically: true)
                    }
                    try await Task.sleep(for: .seconds(6 * 60 * 60))
                }
            } catch { }
            self.automaticCheck = nil
        }
    }
    func checkForUpdates(dataDirectory: URL, automatically: Bool = false) {
        if let sparkle {sparkle.check(quiet:automatically);return}
        start(dataDirectory: dataDirectory) {
            guard let authority = self.authority else { throw ValidationError("Install a published Neutrino release to enable updates.") }
            self.message = "Checking GitHub releases…"
            let list = self.directory!.appendingPathComponent("releases-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: list) }
            try await ReleaseDownload.download(URL(string: "https://api.github.com/repos/starharbor2491/neutrino-browser/releases?per_page=100")!, to: list, limit: 2_097_152) { _ in }
            guard let url = try GitHubBrowserRelease.catalogURL(in: Data(contentsOf: list), previews: authority.includesPreviews) else {
                self.available = []; self.message = "Neutrino is up to date. No newer release is published in this update channel."; return
            }
            let file = self.directory!.appendingPathComponent("catalog-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            try await ReleaseDownload.download(url, to: file, limit: 1_048_576) { _ in }
            try Task.checkCancellation()
            let catalog = try JSONDecoder().decode(DistributionCatalog.self, from: Data(contentsOf: file))
            try catalog.validate()
            let current = try ReleaseTrust.metadata(of: Bundle.main.bundleURL, requireCompatibleArchitecture: false)
            let floor = try self.securityFloor()
            self.available = catalog.updates(current: current, minimumEpoch: floor, architecture: Self.architecture)
            self.message = self.available.isEmpty ? "Neutrino is up to date." : "A new Neutrino release is available. Your browser data is kept."
            if automatically, self.automaticUpdates, let asset = self.available.first {
                self.automaticDownload = true
                defer { self.automaticDownload = false }
                try await self.downloadAndStage(asset)
            }
        }
    }
    func install(_ asset: DistributionAsset, dataDirectory: URL) {
        start(dataDirectory: dataDirectory) {
            try await self.downloadAndStage(asset)
        }
    }
    private func downloadAndStage(_ asset: DistributionAsset) async throws {
            try asset.validate()
            guard self.authority != nil else { throw ValidationError("Install a published Neutrino release to enable updates.") }
            let current = try ReleaseTrust.metadata(of: Bundle.main.bundleURL, requireCompatibleArchitecture: false)
            try asset.release.validate(current: current, minimumEpoch: self.securityFloor(), architecture: Self.architecture)
            let file = self.directory!.appendingPathComponent("download-\(UUID().uuidString).dmg")
            defer { try? FileManager.default.removeItem(at: file) }
            self.message = "Downloading Neutrino \(asset.release.version)…"
            let token = self.generation
            try await ReleaseDownload.download(asset.url, to: file, limit: asset.bytes) { fraction in
                Task { @MainActor in if self.busy && self.generation == token { self.progress = fraction } }
            }
            try Task.checkCancellation()
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let digest = try await Self.background { try Self.sha256(file) }
            guard Int64(size) == asset.bytes, digest == asset.sha256 else {
                throw ValidationError("The download failed its size or integrity check. The installed app has been kept.")
            }
            self.progress = nil
            try await self.stage(file, expected: asset.release, codeDirectoryHash: asset.codeDirectoryHash)
    }
    func importInstaller(dataDirectory: URL) {
        guard !busy, !terminationPending else { return }
        let panel = NSOpenPanel()
        panel.title = "Import a Neutrino installer"
        panel.message = "Choose an official signed Neutrino.app or offline Neutrino disk image. Neutrino profiles, saved records, modules, and layout are kept. A WebKit-only installer requires confirmation before removing Chromium."
        panel.allowedContentTypes = [.applicationBundle, .diskImage]
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              ["app", "dmg"].contains(url.pathExtension.lowercased()) else { return }
        start(dataDirectory: dataDirectory) {
            guard case .developerID = self.authority else { throw ValidationError("Offline import requires a Developer ID signed installation. Preview updates download directly from GitHub.") }
            try await self.stage(url, expected: nil, codeDirectoryHash: nil)
        }
    }
    func requestRestart() {
        guard pending != nil, !busy else { return }
        installOnQuit = true
        restartRequested = true
        NSApp.terminate(nil)
    }
    func cancelledQuit() {
        terminationPending = false
        restartRequested = false
        installOnQuit = automaticUpdates && pending != nil && pending?.chromium == current?.chromium
        scheduleAutomaticChecks()
        if let process = installerProcess, process.isRunning { process.terminate() }
        if let executable = installerHelper,
           executable.deletingLastPathComponent() == directory, executable.lastPathComponent.hasPrefix("NeutrinoUpdater-") {
            try? FileManager.default.removeItem(at: executable)
            try? FileManager.default.removeItem(at: executable.appendingPathExtension("ready"))
        }
        installerProcess = nil; installerHelper = nil; installerStarted = false
    }
    func discardPending() {
        guard !busy, !terminationPending, !installerStarted, let directory else { return }
        let stage = candidate?.deletingLastPathComponent() ?? rejectedStage
        busy = true; progress = nil; message = "Removing the staged installer…"
        cleanupOperation = Task {
            defer { self.busy = false; self.cleanupOperation = nil }
            do {
                try await Self.background {
                    let fm = FileManager.default
                    if let stage, fm.fileExists(atPath: stage.path) {
                        let name = stage.lastPathComponent
                        guard stage.isFileURL, directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL,
                              stage.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                              name.hasPrefix("stage-"), UUID(uuidString: String(name.dropFirst(6)))?.uuidString == String(name.dropFirst(6)),
                              (try stage.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
                              (try stage.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                            throw ValidationError("The staged installer location changed. Its files were kept.")
                        }
                        try fm.removeItem(at: stage)
                    }
                    let record = directory.appendingPathComponent("pending-install.json")
                    if fm.fileExists(atPath: record.path) { try fm.removeItem(at: record) }
                }
                self.candidate = nil; self.rejectedStage = nil; self.destination = nil; self.pending = nil
                self.installOnQuit = false; self.restartRequested = false; self.pendingCodeHash = nil; self.pendingRecordInvalid = false
                self.message = "The staged installer was removed. Your installed application is unchanged."
            } catch { self.message = error.localizedDescription }
        }
    }
    /// Start after data flush/quit approval and before irreversible engine
    /// shutdown. The helper only activates after this PID exits. If quit is
    /// refused, cancelledQuit() stops the helper while the parent remains alive.
    func launchPendingInstaller() async throws {
        guard let candidate, let destination, let directory, pending != nil, installOnQuit, !installerStarted else { return }
        guard let authority else { throw ValidationError("The Neutrino update authority is unavailable.") }
        try ReleaseTrust.verifyDestinationIsNotRunning(destination, excludingPID: ProcessInfo.processInfo.processIdentifier)
        let current = try ReleaseTrust.metadata(of: Bundle.main.bundleURL, requireCompatibleArchitecture: false), floor = try securityFloor()
        let codeHash = pendingCodeHash
        try await Self.background { try Self.verify(candidate, authority: authority, codeHash: codeHash, current: current, floor: floor) }
        let bundledHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Updater/" + Self.architecture + "/NeutrinoUpdater")
        let helper = directory.appendingPathComponent("NeutrinoUpdater-\(UUID().uuidString)")
        do {
            try await Self.background {
                let hash = try ReleaseTrust.verifyCodeIntegrity(bundledHelper, identifier: "org.neutrino.updater")
                if case .developerID(let team,_) = authority { try ReleaseTrust.verifySignature(bundledHelper, team: team, identifier: "org.neutrino.updater", notarized: false) }
                try FileManager.default.copyItem(at: bundledHelper, to: helper)
                guard try ReleaseTrust.verifyCodeIntegrity(helper, identifier: "org.neutrino.updater") == hash else { throw ValidationError("The copied updater changed.") }
            }
        } catch {
            try? FileManager.default.removeItem(at: helper)
            throw error
        }
        let process = Process(); process.executableURL = helper
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), candidate.path, destination.path,
                             journalURL!.path, String(floor), Bundle.main.bundlePath, codeHash ?? "", restartRequested ? "restart" : "quit"]
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run(); installerProcess = process; installerHelper = helper
            let ready = helper.appendingPathExtension("ready")
            let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(60))
            while !FileManager.default.fileExists(atPath: ready.path) {
                try Task.checkCancellation()
                guard process.isRunning, clock.now < deadline else { throw ValidationError("The verified updater did not become ready. Neutrino has stayed open.") }
                try await Task.sleep(for: .milliseconds(50))
            }
            let values = try ready.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            let readyHandle = try FileHandle(forReadingFrom: ready)
            defer { try? readyHandle.close() }
            let response = try readyHandle.read(upToCount: 6) ?? Data()
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == 5,
                  response == Data("READY".utf8), process.isRunning else {
                throw ValidationError("The updater's readiness response was invalid. Neutrino has stayed open.")
            }
            try FileManager.default.removeItem(at: ready)
            installerStarted = true
        } catch {
            cancelledQuit()
            try? FileManager.default.removeItem(at: helper)
            throw error
        }
    }
    private func start(dataDirectory: URL, action: @escaping @MainActor () async throws -> Void) {
        guard !busy, !terminationPending, pending == nil, !pendingRecordInvalid else { return }
        configure(dataDirectory: dataDirectory)
        guard directory != nil else { return }
        generation = UUID(); busy = true; progress = nil; message = nil
        operation = Task {
            defer { self.busy = false; self.progress = nil; self.operation = nil }
            do { try await action() }
            catch is CancellationError { self.message = "Installation cancelled. Your installed app is unchanged." }
            catch { self.message = error.localizedDescription }
        }
    }
    private func stage(_ installer: URL, expected: DistributionRelease?, codeDirectoryHash: String?) async throws {
        guard let authority else { throw ValidationError("The Neutrino update authority is unavailable.") }
        let current = try ReleaseTrust.metadata(of: Bundle.main.bundleURL, requireCompatibleArchitecture: false)
        let stage = directory!.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let imported = stage.appendingPathComponent("Neutrino.app", isDirectory: true)
        do {
            message = "Verifying the installer…"
            let floor = try securityFloor()
            if installer.pathExtension.lowercased() == "dmg" {
                let values = try installer.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let bytes = values.fileSize, bytes > 0, bytes <= 4_000_000_000 else {
                    throw ValidationError("Choose a regular Neutrino disk image smaller than 4 GB.")
                }
                let mount = directory!.appendingPathComponent("mount-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
                do {
                    try await Self.runTool("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, installer.path], timeout: 120)
                    let source = mount.appendingPathComponent("Neutrino.app", isDirectory: true)
                    guard FileManager.default.fileExists(atPath: source.path) else {
                        throw ValidationError("This mounted image does not contain Neutrino.app. If the installer is already open in Finder, import Neutrino.app inside it instead.")
                    }
                    try await Self.background {
                        try Self.verify(source, authority: authority, codeHash: codeDirectoryHash, current: current, floor: floor)
                        try Task.checkCancellation()
                        try FileManager.default.copyItem(at: source, to: imported)
                    }
                    try await Self.runTool("/usr/bin/hdiutil", ["detach", mount.path], timeout: 30)
                    try? FileManager.default.removeItem(at: mount)
                } catch {
                    // Detach even on cancellation. Do not force an in-use volume.
                    _ = try? await Self.runTool("/usr/bin/hdiutil", ["detach", mount.path], timeout: 30, ignoreCancellation: true)
                    try? FileManager.default.removeItem(at: mount)
                    throw error
                }
            } else {
                try await Self.background {
                    try Self.verify(installer, authority: authority, codeHash: codeDirectoryHash, current: current, floor: floor)
                    try Task.checkCancellation()
                    try FileManager.default.copyItem(at: installer, to: imported)
                }
            }
            try Task.checkCancellation()
            let release = try await Self.background {
                try Self.verify(imported, authority: authority, codeHash: codeDirectoryHash, current: current, floor: floor)
                return try ReleaseTrust.metadata(of: imported)
            }
            if let expected, release != expected { throw ValidationError("The signed installer does not match the advertised release.") }
            if expected == nil, current.chromium, !release.chromium {
                let alert = NSAlert()
                alert.messageText = "Stage a WebKit-only installer and remove Chromium?"
                alert.informativeText = Self.chromiumRemovalNotice + " Replacement happens only after you choose Restart and install."
                alert.addButton(withTitle: "Stage installer"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
                try Task.checkCancellation()
            }
            guard let installDestination = chooseDestination() else {
                if automaticDownload { throw ValidationError("Move Neutrino to a writable Applications folder, then check for updates again.") }
                throw CancellationError()
            }
            try ReleaseTrust.verifyDestinationIsNotRunning(installDestination, excludingPID: ProcessInfo.processInfo.processIdentifier)
            if FileManager.default.fileExists(atPath: installDestination.path) {
                try await Self.background {
                    try ReleaseTrust.verifyBundleTree(installDestination)
                    switch authority {
                    case .developerID(let team,_): try ReleaseTrust.verifySignature(installDestination, team: team, identifier: "org.neutrino.browser", notarized: true)
                    case .githubPreview: _ = try ReleaseTrust.verifyCodeIntegrity(installDestination, identifier: "org.neutrino.browser")
                    }
                    let installed = try ReleaseTrust.metadata(of: installDestination, requireCompatibleArchitecture: false)
                    try release.validate(current: installed, minimumEpoch: floor, architecture: Self.architecture)
                }
            }
            try Task.checkCancellation()
            let saved = PendingInstall(candidate: imported, destination: installDestination, release: release, codeDirectoryHash: codeDirectoryHash)
            try JSONEncoder().encode(saved).write(to: directory!.appendingPathComponent("pending-install.json"), options: [.atomic])
            candidate = imported; rejectedStage = nil; destination = installDestination; pending = release
            pendingCodeHash = codeDirectoryHash; installOnQuit = automaticUpdates && release.chromium == current.chromium
            message = readyMessage(for: release, current: current)
        } catch {
            // Cancellation must still finish removing this owned disposable
            // stage. A detached cleanup keeps filesystem work off the UI actor.
            let cleanupError = await Task.detached(priority: .utility) {
                do { try FileManager.default.removeItem(at: stage); return nil as String? }
                catch { return error.localizedDescription }
            }.value
            if cleanupError != nil {
                rejectedStage = stage; pendingRecordInvalid = true
            }
            throw error
        }
    }
    private func restorePending(authority: ReleaseTrust.UpdateAuthority) async throws {
        guard let directory else { return }
        let file = directory.appendingPathComponent("pending-install.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= 8192 else {
            throw ValidationError("The staged installer record is invalid. Your installed app is unchanged.")
        }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let data = try handle.read(upToCount: 8193) ?? Data()
        guard data.count <= 8192 else { throw ValidationError("The staged installer record is too large.") }
        let saved = try JSONDecoder().decode(PendingInstall.self, from: data)
        let stage = saved.candidate.deletingLastPathComponent()
        let name = stage.lastPathComponent
        guard saved.candidate.isFileURL, saved.destination.isFileURL,
              saved.candidate.lastPathComponent == "Neutrino.app", saved.destination.pathExtension == "app",
              stage.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              name.hasPrefix("stage-"), UUID(uuidString: String(name.dropFirst(6)))?.uuidString == String(name.dropFirst(6)) else {
            throw ValidationError("The staged installer record references an invalid location.")
        }
        if !FileManager.default.fileExists(atPath: saved.candidate.path),
           let current, current == saved.release {
            // The helper completed activation and removed its source before a
            // previous process could remove the pending record.
            try FileManager.default.removeItem(at: file)
            return
        }
        let stageValues = try stage.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard stageValues.isDirectory == true, stageValues.isSymbolicLink != true else { throw ValidationError("The staged installer location is not a real directory.") }
        rejectedStage = stage
        let current = try ReleaseTrust.metadata(of: Bundle.main.bundleURL, requireCompatibleArchitecture: false), floor = try securityFloor()
        try await Self.background {
            try Self.verify(saved.candidate, authority: authority, codeHash: saved.codeDirectoryHash, current: current, floor: floor)
            guard try ReleaseTrust.metadata(of: saved.candidate) == saved.release else { throw ValidationError("The staged installer version changed.") }
        }
        guard !Task.isCancelled, !terminationPending else { return }
        candidate = saved.candidate; destination = saved.destination; pending = saved.release
        pendingCodeHash = saved.codeDirectoryHash; installOnQuit = automaticUpdates && saved.release.chromium == current.chromium
        rejectedStage = nil
        message = readyMessage(for: saved.release, current: current)
    }
    private func readyMessage(for release: DistributionRelease, current: DistributionRelease) -> String {
        if current.chromium, !release.chromium {
            return "Neutrino \(release.version) is ready. Restart to use WebKit and remove Chromium. " + Self.chromiumRemovalNotice
        }
        return "Neutrino \(release.version) is ready. \(automaticUpdates ? "It installs when you quit." : "Choose Restart and install.") Your profiles, website sign-ins, saved records, modules, and layout are kept."
    }
    private func chooseDestination() -> URL? {
        let current = Bundle.main.bundleURL.standardizedFileURL
        let parent = current.deletingLastPathComponent()
        // App Translocation/disk images must never be used as update targets.
        if !current.path.hasPrefix("/Volumes/"), !current.path.contains("/AppTranslocation/"),
           FileManager.default.isWritableFile(atPath: parent.path), FileManager.default.isWritableFile(atPath: current.path) {
            return current
        }
        if automaticDownload { return nil }
        let panel = NSOpenPanel()
        panel.title = "Choose the Neutrino installation folder"
        panel.message = "Neutrino cannot replace this copy in its current location. Choose a writable Applications folder. The new app uses your existing browser data."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let selected = panel.url,
              FileManager.default.isWritableFile(atPath: selected.path),
              selected.resolvingSymlinksInPath().standardizedFileURL == selected.standardizedFileURL else { return nil }
        return selected.appendingPathComponent("Neutrino.app", isDirectory: true)
    }
    private var journalURL: URL? { directory?.appendingPathComponent("replacement-journal.json") }
    private func securityFloor() throws -> Int {
        let currentEpoch = current?.securityEpoch ?? 0
        guard let directory else { return currentEpoch }
        let file = directory.appendingPathComponent("security-floor.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return currentEpoch }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 64 else { throw ValidationError("The saved engine security version is invalid. Use Recovery to inspect the update files.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 65) ?? Data()
        guard !data.isEmpty, data.count <= 64 else { throw ValidationError("The saved engine security version is invalid.") }
        let accepted = try JSONDecoder().decode(Int.self, from: data)
        guard accepted >= 0 else { throw ValidationError("The saved security version is invalid.") }
        return max(currentEpoch, accepted)
    }
    nonisolated private static var architecture: String {
        ReleaseTrust.platformArchitecture
    }
    nonisolated private static func verify(_ app: URL, authority: ReleaseTrust.UpdateAuthority, codeHash: String?, current: DistributionRelease, floor: Int) throws {
        try ReleaseTrust.verifyUpdate(app, authority: authority, codeDirectoryHash: codeHash)
        try ReleaseTrust.metadata(of: app).validate(current: current, minimumEpoch: floor, architecture: architecture)
    }
    nonisolated private static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256(), bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            bytes += Int64(chunk.count); guard bytes <= 4_000_000_000 else { throw ValidationError("The installer is too large.") }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    nonisolated private static func background<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let result = try operation()
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    private static func runTool(_ path: String, _ arguments: [String], timeout: Int, ignoreCancellation: Bool = false) async throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(timeout))
        do {
            while process.isRunning {
                if !ignoreCancellation { try Task.checkCancellation() }
                guard clock.now < deadline else { throw ValidationError("The installer operation timed out.") }
                if ignoreCancellation { try? await Task.sleep(for: .milliseconds(50)) }
                else { try await Task.sleep(for: .milliseconds(50)) }
            }
            guard process.terminationStatus == 0 else { throw ValidationError("The disk image could not be opened or unmounted. Choose an official Neutrino installer.") }
        } catch {
            if process.isRunning { process.terminate(); try? await Task.sleep(for: .milliseconds(250)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit(); throw error
        }
    }
}

private final class ReleaseDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let limit: Int64
    private let progress: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var completed = false
    private var saved = false
    private var failure: Error?
    private var cancelled = false
    private init(destination: URL, limit: Int64, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination; self.limit = limit; self.progress = progress
    }
    static func download(_ url: URL, to destination: URL, limit: Int64, progress: @escaping @Sendable (Double?) -> Void) async throws {
        let job = ReleaseDownload(destination: destination, limit: limit, progress: progress)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                job.lock.lock(); job.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil; config.urlCache = nil
                config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 1800
                let session = URLSession(configuration: config, delegate: job, delegateQueue: nil)
                job.session = session
                let cancelled = job.cancelled
                job.lock.unlock()
                if cancelled { job.finish(CancellationError()) }
                else { session.downloadTask(with: url).resume() }
            }
        } onCancel: { job.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let session = session; lock.unlock()
        session?.invalidateAndCancel()
        finish(CancellationError())
    }
    private func finish(_ error: Error?) {
        lock.lock()
        guard !completed, let continuation else { lock.unlock(); return }
        completed = true; self.continuation = nil; let session = session; self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        if let error { try? FileManager.default.removeItem(at: destination); continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let hosts = ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
        completionHandler(request.url?.scheme == "https" && hosts.contains(request.url?.host ?? "") ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            lock.lock(); failure = ValidationError("The installer download exceeds its size limit."); lock.unlock()
            downloadTask.cancel()
        }
        else { progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); defer { lock.unlock() }
        guard !completed, !cancelled else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https",
                  ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(response.url?.host ?? ""),
                  Int64(try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= limit else {
                throw ValidationError("The official release is unavailable or its download is invalid.")
            }
            try FileManager.default.moveItem(at: location, to: destination); saved = true
        } catch { failure = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let result = failure ?? error ?? (saved ? nil : ValidationError("The installer download was incomplete.")); lock.unlock()
        finish(result)
    }
}
