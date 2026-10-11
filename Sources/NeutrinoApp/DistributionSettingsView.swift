// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import NeutrinoCore

struct DistributionSettingsView: View {
    let dataDirectory: URL
    @ObservedObject private var distribution = DistributionManager.shared
    var body: some View {
        GroupBox("Installation and updates") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Updates come from Neutrino’s GitHub releases and install after you quit. Your tabs, profiles, website sign-ins, passwords, modules, and appearance stay on this Mac.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let current = distribution.current {
                    LabeledContent("Installed", value: "Neutrino \(current.version) · \(current.chromium ? "WebKit + Chromium" : "WebKit")")
                }
                if !distribution.publisherAvailable {
                    Label("Local builds do not receive updates. Install a published Neutrino release to enable them.", systemImage: "signature")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Automatically download updates and install when I quit", isOn: $distribution.automaticUpdates)
                    .toggleStyle(.switch).disabled(!distribution.publisherAvailable)
                HStack {
                    Button("Check for updates") { distribution.checkForUpdates(dataDirectory: dataDirectory) }
                    Button("Import offline installer…") { distribution.importInstaller(dataDirectory: dataDirectory) }
                }.disabled(distribution.busy || distribution.pending != nil || distribution.pendingRecordInvalid || !distribution.publisherAvailable)
                ForEach(Array(distribution.available.enumerated()), id: \.offset) { _, asset in
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Neutrino \(asset.release.version) · \(asset.release.chromium ? "with Chromium" : "WebKit only")").font(.headline)
                            Text("GitHub release · \(ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file)) · installs after quitting")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Download update") {
                            confirmInstall(asset)
                        }.disabled(distribution.busy || distribution.pending != nil || distribution.pendingRecordInvalid)
                    }
                }
                if distribution.busy {
                    HStack {
                        if let progress = distribution.progress { ProgressView(value: progress).frame(maxWidth: 240) }
                        else { ProgressView().controlSize(.small) }
                        if distribution.canCancel { Button("Cancel") { distribution.cancel() } }
                    }
                }
                if let message = distribution.message {
                    Text(message).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if distribution.pendingRecordInvalid {
                    Button("Discard unfinished installer") { distribution.discardPending() }.disabled(distribution.busy)
                }
                if distribution.pending != nil {
                    HStack {
                        Button("Restart and install") { distribution.requestRestart() }.buttonStyle(.borderedProminent)
                        Button("Discard installer") { distribution.discardPending() }
                    }.disabled(distribution.busy)
                }
            }.padding(8)
        }.onAppear { distribution.configure(dataDirectory: dataDirectory) }
    }
    private func confirmInstall(_ asset: DistributionAsset) {
        let alert = NSAlert()
        let removingChromium = distribution.current?.chromium == true && !asset.release.chromium
        alert.messageText = removingChromium ? "Remove Chromium and restart Neutrino?" : "Download the Neutrino update?"
        alert.informativeText = "The complete Neutrino app is staged and verified before replacement. " + (removingChromium
            ? DistributionManager.chromiumRemovalNotice
            : "Your Neutrino profiles, saved records, installed modules, and layout are kept.\(asset.release.chromium ? " Choose Chromium for future tabs or reopen a tab explicitly to change its engine." : "")")
        alert.addButton(withTitle: "Download installer"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        distribution.install(asset, dataDirectory: dataDirectory)
    }
}
