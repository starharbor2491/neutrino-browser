// SPDX-License-Identifier: MPL-2.0
import AppKit
import Darwin
import NeutrinoCore
import NeutrinoDistribution

/// A separately signed helper waits until the old app exits before replacing its
/// sealed bundle. It never alters App Support, removes quarantine, or disables
/// Gatekeeper. Every copied candidate is verified again on its destination volume.
@main
struct NeutrinoUpdater {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count == 9, let parent = Int32(args[1]), parent > 1,
              let epoch = Int(args[5]), epoch >= 0, ["restart", "quit"].contains(args[8]) else { return }
        let source = URL(fileURLWithPath: args[2]).standardizedFileURL
        let destination = URL(fileURLWithPath: args[3]).standardizedFileURL
        let journal = URL(fileURLWithPath: args[4]).standardizedFileURL
        let currentApp = URL(fileURLWithPath: args[6]).standardizedFileURL
        let helper = URL(fileURLWithPath: args[0]).standardizedFileURL
        var activated = false
        defer {
            if helper.deletingLastPathComponent() == journal.deletingLastPathComponent(), helper.lastPathComponent.hasPrefix("NeutrinoUpdater-") {
                try? FileManager.default.removeItem(at: helper)
                try? FileManager.default.removeItem(at: helper.appendingPathExtension("ready"))
            }
        }
        do {
            let authority = try ReleaseTrust.updateAuthority(of: currentApp)
            let bundledHelper = currentApp.appendingPathComponent("Contents/Resources/Updater/arm64/NeutrinoUpdater")
            guard try ReleaseTrust.verifyCodeIntegrity(helper, identifier: "org.neutrino.updater") == ReleaseTrust.verifyCodeIntegrity(bundledHelper, identifier: "org.neutrino.updater") else {
                throw ValidationError("The updater does not match the installed application.")
            }
            if case .developerID(let team) = authority { try ReleaseTrust.verifySignature(helper, team: team, identifier: "org.neutrino.updater", notarized: false) }
            let current = try ReleaseTrust.metadata(of: currentApp, requireCompatibleArchitecture: false)
            let architecture: String
            #if arch(arm64)
            architecture = "arm64"
            #else
            architecture = "x86_64"
            #endif
            let sourceRelease = try ReleaseTrust.metadata(of: source)
            let verify: (URL) throws -> Void = { app in
                try ReleaseTrust.verifyUpdate(app, authority: authority, codeDirectoryHash: args[7].isEmpty ? nil : args[7])
                let release = try ReleaseTrust.metadata(of: app)
                guard release == sourceRelease else { throw ValidationError("The staged application changed after approval.") }
                try release.validate(current: current, minimumEpoch: epoch, architecture: architecture)
            }
            let verifyExisting: (URL) throws -> Void = { app in
                // Restoring the original app after a failed rename is not
                // activating an older candidate. It remains unlaunched; all new
                // candidates must meet the current build/security floor above.
                try ReleaseTrust.verifyBundleTree(app)
                switch authority {
                case .developerID(let team): try ReleaseTrust.verifySignature(app, team: team, identifier: "org.neutrino.browser", notarized: true)
                case .githubPreview: _ = try ReleaseTrust.verifyCodeIntegrity(app, identifier: "org.neutrino.browser")
                }
            }
            try verify(source)
            let verifyInstalledForUpdate: (URL) throws -> Void = { app in
                try verifyExisting(app)
                let installed = try ReleaseTrust.metadata(of: app, requireCompatibleArchitecture: false)
                try sourceRelease.validate(current: installed, minimumEpoch: epoch, architecture: architecture)
            }
            if FileManager.default.fileExists(atPath: destination.path) { try verifyInstalledForUpdate(destination) }
            try ReleaseTrust.verifyDestinationIsNotRunning(destination, excludingPID: parent)
            let ready = helper.appendingPathExtension("ready")
            guard helper.deletingLastPathComponent() == journal.deletingLastPathComponent(),
                  helper.lastPathComponent.hasPrefix("NeutrinoUpdater-"),
                  UUID(uuidString: String(helper.lastPathComponent.dropFirst(14))) != nil else {
                throw ValidationError("The updater must be launched from its private staging directory.")
            }
            try Data("READY".utf8).write(to: ready, options: [.atomic])
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(120))
            while kill(parent, 0) == 0 {
                guard clock.now < deadline else { throw ValidationError("Neutrino did not finish quitting. The update was left staged.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard errno == ESRCH else { throw ValidationError("Could not confirm that Neutrino has quit. The update was left staged.") }
            try ReleaseTrust.verifyDestinationIsNotRunning(destination, excludingPID: parent)
            try AppReplacementTransaction.recover(journalURL: journal, expectedDestination: destination, verify: verify, verifyExisting: verifyExisting)
            try AppReplacementTransaction.install(source: source, destination: destination, journalURL: journal, verify: verify, verifyExisting: verifyInstalledForUpdate, checkpoint: { phase in
                if phase == "copied" { try ReleaseTrust.verifyDestinationIsNotRunning(destination, excludingPID: parent) }
            })
            activated = true
            // Keep the security floor beside browser data. Removing Chromium must
            // not enable a subsequent older Chromium installation.
            let floor = journal.deletingLastPathComponent().appendingPathComponent("security-floor.json")
            let release = try ReleaseTrust.metadata(of: destination)
            let accepted = max(epoch, release.securityEpoch)
            try JSONEncoder().encode(accepted).write(to: floor, options: [.atomic])
            try? FileManager.default.removeItem(at: source)
            if (try? FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path).isEmpty) == true {
                try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            }
            try? FileManager.default.removeItem(at: journal.deletingLastPathComponent().appendingPathComponent("pending-install.json"))
            if args[8] == "restart" {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = true
                _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
            }
        } catch {
            if ProcessInfo.processInfo.environment["NEUTRINO_UPDATER_HEADLESS"] == "1" {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = activated ? "Neutrino was installed but could not finish restarting" : "Neutrino could not finish the installation"
            alert.informativeText = error.localizedDescription + (activated
                ? " Your browser data is kept. Open the installed Neutrino app to retry any unfinished setup."
                : " Your browser data is kept. Open your previous Neutrino app or import the installer again.")
            alert.addButton(withTitle: activated ? "Open Neutrino" : "OK")
            if activated { alert.addButton(withTitle: "Later") }
            if alert.runModal() == .alertFirstButtonReturn, activated {
                do {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.createsNewApplicationInstance = true
                    _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
                } catch {
                    let launchAlert = NSAlert()
                    launchAlert.messageText = "Open Neutrino from your installation folder"
                    launchAlert.informativeText = error.localizedDescription
                    launchAlert.runModal()
                }
            }
        }
    }
}
