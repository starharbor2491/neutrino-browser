// SPDX-License-Identifier: MPL-2.0
import AppKit
import Foundation
import NeutrinoCore
@preconcurrency import Sparkle

/// Native framework adapter. Signed feeds and complete .app archives live on GitHub.
/// Sparkle requests the application's ordinary, vetoable quit before replacement.
@MainActor
final class SparkleUpdates: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var scheduledInstallation = false
    var canUninstall: Bool { !scheduledInstallation && !controller.updater.sessionInProgress }
    static func make(automatic: Bool) -> SparkleUpdates? {
        guard let key=Bundle.main.object(forInfoDictionaryKey:"SUPublicEDKey") as? String,
              Data(base64Encoded:key)?.count==32,
              let feed=Bundle.main.object(forInfoDictionaryKey:"SUFeedURL") as? String,
              let url=URL(string:feed), url.scheme=="https", url.host=="raw.githubusercontent.com",
              ProcessInfo.processInfo.environment["NEUTRINO_SMOKE_TEST_DATA"]==nil,
              !CommandLine.arguments.contains(where:{$0.contains("xctest")}) else {return nil}
        return SparkleUpdates(automatic:automatic)
    }
    private init(automatic: Bool) {
        super.init()
        controller=SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:self,userDriverDelegate:nil)
        setAutomatic(automatic)
        controller.startUpdater()
    }
    func setAutomatic(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates=enabled
        controller.updater.automaticallyDownloadsUpdates=enabled
    }
    func check(quiet: Bool) {
        if quiet {controller.updater.checkForUpdatesInBackground()}
        else {controller.checkForUpdates(nil)}
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard AppDelegate.state?.uninstallRequested != true else { throw ValidationError("Neutrino is being uninstalled.") }
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard AppDelegate.state?.uninstallRequested != true else { throw ValidationError("Neutrino is being uninstalled.") }
        try DistributionManager.shared.acceptSparkle(build: item.versionString, epoch: item.propertiesDictionary["neutrinoSecurityEpoch"] as? String)
    }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        scheduledInstallation = true
        return false
    }
}
