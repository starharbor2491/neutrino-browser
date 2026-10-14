// SPDX-License-Identifier: MPL-2.0
import AppKit
import Foundation
@preconcurrency import Sparkle

/// Native framework adapter. Signed feeds and complete .app archives live on GitHub.
/// Sparkle requests the application's ordinary, vetoable quit before replacement.
@MainActor
final class SparkleUpdates {
    private let controller: SPUStandardUpdaterController
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
        controller=SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:nil,userDriverDelegate:nil)
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
}
