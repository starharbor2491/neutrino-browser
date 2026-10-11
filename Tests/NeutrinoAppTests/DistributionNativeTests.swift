// SPDX-License-Identifier: MPL-2.0
import Foundation
import AppKit
import Security
import Testing
import NeutrinoCore
import NeutrinoDistribution
@testable import NeutrinoApp

extension NativeIntegrationTests {
@Suite(.serialized)
struct DistributionNativeTests {
    @Test func consumerRequirementSupportsNotarizationAndRejectsUnidentifiedCode() throws {
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString("notarized" as CFString, [], &requirement) == errSecSuccess)
        #expect(requirement != nil)
        // The real test executable is development-signed, never a consumer
        // publisher. No test policy is available to the installation UI.
        #expect(throws: (any Error).self) { try ReleaseTrust.publisherTeam(of: Bundle.main.bundleURL) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEUTRINO_DISTRIBUTION_TEST_APP"] != nil))
    func realSignedAppStagesAtomicallyAndDamagedCopyRollsBack() throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NEUTRINO_DISTRIBUTION_TEST_APP"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Neutrino-install-native-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent("Candidate.app"), installed = root.appendingPathComponent("Neutrino.app")
        try FileManager.default.copyItem(at: fixture, to: candidate)
        try FileManager.default.copyItem(at: fixture, to: installed)
        let initial = try ReleaseTrust.metadata(of: candidate)
        let journal = root.appendingPathComponent("journal.json")
        let data = root.appendingPathComponent("UserData.json")
        try Data("kept".utf8).write(to: data)
        // Explicit CI-only verifier exercises the exact transaction with real
        // native bundles and code-integrity checks. Production calls always use
        // ReleaseTrust's Developer ID + same-publisher + notarized requirement.
        let integrity: (URL) throws -> Void = Self.verifyNativeFixture
        try AppReplacementTransaction.install(source: candidate, destination: installed, journalURL: journal, verify: integrity)
        #expect(try ReleaseTrust.metadata(of: installed) == initial)
        #expect(try String(contentsOf: data, encoding: .utf8) == "kept")
        try Data("damaged".utf8).write(to: candidate.appendingPathComponent("Contents/Resources/Distribution.json"))
        #expect(throws: (any Error).self) {
            try AppReplacementTransaction.install(source: candidate, destination: installed, journalURL: journal, verify: integrity)
        }
        #expect(try ReleaseTrust.metadata(of: installed) == initial)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(throws: (any Error).self) { try ReleaseTrust.publisherTeam(of: installed) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEUTRINO_DISTRIBUTION_TEST_APP"] != nil))
    func replacingABundleAtTheSameURLReadsItsNewSignedVersionInsteadOfCachedInfo() throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NEUTRINO_DISTRIBUTION_TEST_APP"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Neutrino-version-update-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent("Candidate.app"), installed = root.appendingPathComponent("Neutrino.app")
        try FileManager.default.copyItem(at: fixture, to: candidate)
        try FileManager.default.copyItem(at: fixture, to: installed)
        let old = try ReleaseTrust.metadata(of: installed)
        let cachedBundle = try #require(Bundle(url: installed))
        #expect(cachedBundle.infoDictionary?["CFBundleVersion"] as? String == String(old.build))
        try #require(old.build < Int.max)
        let replacement = DistributionRelease(build: old.build + 1, version: "\(old.build + 1).0.0", securityEpoch: old.securityEpoch,
            architecture: old.architecture, chromium: old.chromium, minimumMacOS: old.minimumMacOS ?? "14.0")
        let infoURL = candidate.appendingPathComponent("Contents/Info.plist")
        var info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
        info["CFBundleVersion"] = String(replacement.build)
        info["CFBundleShortVersionString"] = replacement.version
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL, options: .atomic)
        try JSONEncoder().encode(replacement).write(to: candidate.appendingPathComponent("Contents/Resources/Distribution.json"), options: .atomic)
        // Sign this fixture after changing its sealed metadata. Development
        // integrity is available only in this test, never in the consumer UI.
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", "--preserve-metadata=identifier,entitlements,flags", "--timestamp=none", candidate.path]
        signer.standardInput = FileHandle.nullDevice
        try signer.run(); signer.waitUntilExit()
        try #require(signer.terminationStatus == 0)
        try Self.verifyNativeFixture(candidate)
        #expect(try ReleaseTrust.metadata(of: candidate) == replacement)

        try AppReplacementTransaction.install(source: candidate, destination: installed, journalURL: root.appendingPathComponent("journal.json"),
            verify: Self.verifyNativeFixture, verifyExisting: Self.verifyNativeFixture)

        // Keep the original Bundle alive across the rename. The updater must
        // inspect the new sealed files even if Foundation keeps the old cache.
        let activated = try withExtendedLifetime(cachedBundle) { try ReleaseTrust.metadata(of: installed) }
        #expect(activated == replacement)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("journal.json").path))
    }

    private static func verifyNativeFixture(_ app: URL) throws {
        try ReleaseTrust.verifyBundleTree(app)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw ValidationError("Damaged native fixture")
        }
        _ = try ReleaseTrust.metadata(of: app)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEUTRINO_DISTRIBUTION_TEST_APP"] != nil))
    @MainActor func previewUpdaterWaitsForExitReplacesAppAndPreservesProfileData() async throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NEUTRINO_DISTRIBUTION_TEST_APP"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Neutrino-real-updater-" + UUID().uuidString).resolvingSymlinksInPath()
        let updates = root.appendingPathComponent("UserData/Updates")
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("Neutrino.app"), candidate = root.appendingPathComponent("stage/Neutrino.app")
        try FileManager.default.createDirectory(at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: installed)
        try Self.signPreviewFixture(installed, incrementBuild: false)
        #expect(try ReleaseTrust.updateAuthority(of: installed) == .githubPreview)
        try FileManager.default.copyItem(at: installed, to: candidate)
        try Self.signPreviewFixture(candidate, incrementBuild: true)
        let old = try ReleaseTrust.metadata(of: installed), next = try ReleaseTrust.metadata(of: candidate)
        // Use the same independent Apple CLI as release packaging, rather than
        // deriving both sides of the comparison through our verifier.
        let codeHash = try Self.packagedCodeHash(candidate)
        #expect(try ReleaseTrust.verifyCodeIntegrity(candidate, identifier: "org.neutrino.browser") == codeHash)
        #expect(throws: (any Error).self) { try ReleaseTrust.verifyUpdate(candidate, authority: .githubPreview, codeDirectoryHash: nil) }
        #expect(throws: (any Error).self) { try ReleaseTrust.verifyUpdate(candidate, authority: .githubPreview, codeDirectoryHash: String(repeating: "0", count: 40)) }
        try ReleaseTrust.verifyUpdate(candidate, authority: .githubPreview, codeDirectoryHash: codeHash)
        var saved: [URL: Data] = [:]
        for relative in ["library.sqlite", "Chromium/profile/Cookies", "WebKit/profile/WebsiteData", "Modules/custom.json", "preferences.json"] {
            let path = root.appendingPathComponent("UserData/" + relative)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data((relative + "-preserved").utf8); try bytes.write(to: path); saved[path] = bytes
        }
        let parent = Process(); parent.executableURL = URL(fileURLWithPath: "/bin/sleep"); parent.arguments = ["300"]
        try parent.run()
        defer { if parent.isRunning { parent.terminate(); parent.waitUntilExit() } }
        let helper = updates.appendingPathComponent("NeutrinoUpdater-" + UUID().uuidString)
        try FileManager.default.copyItem(at: installed.appendingPathComponent("Contents/Resources/Updater/arm64/NeutrinoUpdater"), to: helper)
        let process = Process(); process.executableURL = helper
        process.environment = ProcessInfo.processInfo.environment.merging(["NEUTRINO_UPDATER_HEADLESS": "1"]) { _, new in new }
        let journal = updates.appendingPathComponent("replacement-journal.json")
        process.arguments = [String(parent.processIdentifier), candidate.path, installed.path, journal.path, String(old.securityEpoch), installed.path, codeHash, "quit"]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let ready = helper.appendingPathExtension("ready")
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(90))
        while !FileManager.default.fileExists(atPath: ready.path) {
            try #require(process.isRunning && clock.now < deadline, "The real updater did not signal readiness")
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try ReleaseTrust.metadata(of: installed) == old)
        parent.terminate(); parent.waitUntilExit()
        while process.isRunning {
            try #require(clock.now < deadline, "The real updater did not complete replacement")
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(process.terminationStatus == 0)
        #expect(try ReleaseTrust.metadata(of: installed) == next)
        try ReleaseTrust.verifyUpdate(installed, authority: .githubPreview, codeDirectoryHash: codeHash)
        for (path, bytes) in saved { #expect(try Data(contentsOf: path) == bytes) }
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(!FileManager.default.fileExists(atPath: helper.path))
        #expect(try JSONDecoder().decode(Int.self, from: Data(contentsOf: updates.appendingPathComponent("security-floor.json"))) == next.securityEpoch)
        #expect(!NSRunningApplication.runningApplications(withBundleIdentifier: "org.neutrino.browser").contains { $0.bundleURL == installed })
    }

    private static func signPreviewFixture(_ app: URL, incrementBuild: Bool) throws {
        let infoPath = app.appendingPathComponent("Contents/Info.plist")
        var info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: infoPath), format: nil) as? [String: Any])
        info["NeutrinoUpdateChannel"] = "preview"
        if incrementBuild {
            let old = try ReleaseTrust.metadata(of: app)
            let next = DistributionRelease(build: old.build + 1, version: "1.0.2-preview.1", securityEpoch: old.securityEpoch, architecture: old.architecture, chromium: old.chromium, minimumMacOS: old.minimumMacOS ?? "14.0")
            info["CFBundleVersion"] = String(next.build); info["CFBundleShortVersionString"] = next.version
            try JSONEncoder().encode(next).write(to: app.appendingPathComponent("Contents/Resources/Distribution.json"), options: .atomic)
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoPath, options: .atomic)
        let signer = Process(); signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", "--preserve-metadata=identifier,entitlements,flags", "--timestamp=none", app.path]
        try signer.run(); signer.waitUntilExit(); try #require(signer.terminationStatus == 0)
    }
    private static func packagedCodeHash(_ app: URL) throws -> String {
        let command = Process(); command.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        command.arguments = ["-d", "--verbose=4", "--arch", "arm64", app.path]
        let output = Pipe(); command.standardError = output; command.standardOutput = FileHandle.nullDevice
        try command.run(); command.waitUntilExit(); try #require(command.terminationStatus == 0)
        let text = String(decoding: try output.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("CDHash=") })
        return String(line.dropFirst("CDHash=".count))
    }
}

}
