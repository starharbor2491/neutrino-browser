// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
@preconcurrency import WebKit
import NeutrinoCore

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BrowserModel
    var initialSection: SettingsSection = .general
    @State private var section = SettingsSection.general
    @State private var profileName = ""
    @State private var clearing = false
    @State private var deletingProfile: Profile?
    @ObservedObject private var chromiumRuntime = ChromiumRuntime.shared
    @Environment(\.browserTheme) private var theme
    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "General", profiles = "Profiles", privacy = "Privacy", passwords = "Passwords", ai = "AI", engines = "Browsing engines"
        var id: Self { self }
        var icon: String { switch self { case .general: "gearshape"; case .profiles: "person.crop.circle"; case .privacy: "hand.raised"; case .passwords: "key"; case .ai: "sparkles"; case .engines: "globe" } }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { NeutrinoMark(size: 26); Text("Settings").font(.system(size: 16, weight: .semibold, design: .rounded)) }.padding(.bottom, 22)
                    ForEach(SettingsSection.allCases) { item in Button { section = item } label: { Label(item.rawValue, systemImage: item.icon).font(.system(size: 12, weight: section == item ? .semibold : .regular)).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(section == item ? theme.tint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(section == item ? theme.tint : theme.foreground) }.buttonStyle(.plain) }; Spacer()
                }.padding(20).frame(width: 202).background(theme.canvas)
                VStack(alignment: .leading, spacing: 16) {
                    Text(section.rawValue).font(.system(size: 26, weight: .semibold, design: .rounded))
                    switch section { case .general: general; case .profiles: profiles; case .privacy: privacy; case .passwords: PasswordsView(model: model); case .ai: ScrollView { AIConfigurationView() }; case .engines: engines }
                }.padding(28).frame(maxWidth: .infinity).background(theme.card)
            }
            Divider()
            HStack { if let notice = app.notice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(3) }; Spacer(); Button("Done") { dismiss() }.buttonStyle(NeutrinoButtonStyle(prominent: true)).keyboardShortcut(.defaultAction) }.padding(16).background(theme.card)
        }.frame(width: 820, height: 650)
        .onAppear { section = initialSection }
        .sheet(item: $deletingProfile) { DeleteProfileView(profile: $0) }
    }
    private var general: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Search engine", selection: preference(\.search)) { ForEach(SearchProvider.allCases, id: \.self) { Text($0.label).tag($0) } }
                ChoiceCard(title: "Restore tabs", detail: "Pick up where you left off after reopening Neutrino.", icon: "arrow.counterclockwise", selected: app.library.preferences.restoreSession) { app.library.preferences.restoreSession.toggle() }
                ChoiceCard(title: "Block unsolicited popups", detail: "Requested windows can still open.", icon: "rectangle.badge.xmark", selected: app.library.preferences.blockPopups) { app.library.preferences.blockPopups.toggle() }
                ChoiceCard(title: "Block known ads and trackers", detail: "Use the bundled local domain rules. Reload open pages after changing this setting.", icon: "shield", selected: app.library.preferences.blockTrackers != false) { app.library.preferences.blockTrackers = app.library.preferences.blockTrackers == false; app.windows.values.compactMap(\.model).forEach { $0.updateBlockingPolicy() } }
                Picker("Auto-archive idle regular tabs", selection: Binding(get: { app.library.preferences.autoArchiveDays ?? 0 }, set: { app.library.preferences.autoArchiveDays = $0 == 0 ? nil : $0 })) { Text("Off").tag(0); Text("After 7 days").tag(7); Text("After 30 days").tag(30) }
                Text("Pinned tabs and folder tabs stay. Archived tabs can be restored from each Space’s menu.").font(.caption).foregroundStyle(.secondary)
                Text("Keyboard shortcuts").font(.headline).padding(.top, 10)
                Text("⌘L  Address     ⌘T  New tab     ⌘W  Close tab\n⌘R  Reload       ⌘F  Find          ⌘D  Bookmark\n⌘⇧T  Reopen closed tab     ⌘⇧N  Private window")
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(8)
            }
        }
    }
    private var profiles: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Each profile has separate bookmarks, history, notes, and website storage. Private windows use temporary website storage.").foregroundStyle(.secondary)
            List(app.library.profiles) { profile in
                HStack {
                    TextField("Profile name", text: profileBinding(profile.id)).textFieldStyle(.plain)
                    if profile.id == model.session.profileID { Text("Current").font(.caption).foregroundStyle(.secondary) }
                    else { Button("Switch") { model.switchProfile(profile.id) } }
                    Button("Delete…", role: .destructive) { deletingProfile = profile }
                        .disabled(app.library.profiles.count < 2 || !app.deletingProfileIDs.isEmpty || app.terminating)
                }.padding(.vertical, 5)
            }.listStyle(.inset)
            HStack {
                TextField("New profile name", text: $profileName).textFieldStyle(.roundedBorder)
                Button("Add profile") {
                    let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, app.library.profiles.count < 20 else { return }
                    app.library.profiles.append(Profile(name: String(name.prefix(80)))); profileName = ""
                }.disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.library.profiles.count >= 20)
            }
            Text("Switching profiles reloads open pages and keeps sign-ins separate.").font(.caption).foregroundStyle(.secondary)
            if !(app.library.pendingProfileDeletions ?? []).isEmpty || !(app.library.pendingWebsiteDataClears ?? []).isEmpty {
                HStack { Text("Website storage removal is waiting for a restart.").font(.caption); Spacer(); Button("Quit Neutrino") { NSApp.terminate(nil) } }
            }
        }
    }
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Data for \(model.profile.name)").font(.headline)
            Text("Browser data stays on this Mac. Neutrino has no analytics or cloud sync. Websites make their own network requests.").foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { VStack(alignment: .leading) { Text("Neutrino history"); Text("\(app.library.history.filter { $0.profileID == model.session.profileID }.count) saved visits · Chrome's native history is separate").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Clear…") { clearHistory() } }
                    Divider()
                    HStack { VStack(alignment: .leading) { Text("Website data and Chromium profile"); Text("Clears WebKit site data and resets Chromium, including its extensions, native bookmarks and history").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }; Spacer(); Button(clearing ? "Queuing…" : "Reset…") { clearWebsiteData() }.disabled(clearing) }
                }.padding(8)
            }
            Text("Private browsing avoids saving history and tabs. Saved downloads remain on disk. It does not hide activity from websites, employers, or network providers.").font(.callout).foregroundStyle(.secondary)
            Text("Browser metadata uses SQLite and your Mac’s file permissions. Passwords and AI credentials are stored separately in macOS Keychain.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
    private var engines: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            Text("Choose the engine that displays websites. Your browser controls and recovery stay available independently.").foregroundStyle(.secondary)
            GroupBox {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "globe").font(.title2)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("System WebKit").font(.headline)
                        Text("Available with macOS · No additional download").font(.caption).foregroundStyle(.secondary)
                        Text("Safari's platform web engine. Security updates arrive through macOS updates. Chrome extensions are not supported by WebKit.").font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(8)
            }
            ChromiumSettingsView(dataDirectory: app.dataDirectory)
            DistributionSettingsView(dataDirectory: app.dataDirectory)
            Picker("Default for new tabs in \(model.profile.name)", selection: Binding(get: { model.profile.engineID ?? .webkit }, set: { engine in
                guard let index = app.library.profiles.firstIndex(where: { $0.id == model.session.profileID }) else { return }
                app.library.profiles[index].engineID = engine
            })) {
                Text("WebKit").tag(BrowserEngineID.webkit)
                Text(chromiumRuntime.isInstalled(in: app.dataDirectory) ? "Chromium" : "Chromium (unavailable)").tag(BrowserEngineID.chromium).disabled(!chromiumRuntime.isInstalled(in: app.dataDirectory))
            }
            Text("Existing tabs keep their engine. Use a tab's context menu to reopen it in another engine.").font(.caption).foregroundStyle(.secondary)
            Link("Engine compatibility and release status", destination: URL(string: "https://github.com/starharbor2491/neutrino-browser/blob/main/docs/CHROMIUM.md")!)
            Text("A required engine can be removed only after a compatible replacement is installed. Apple's system WebKit framework is part of macOS.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func preference<T>(_ path: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { app.library.preferences[keyPath: path] }, set: { app.library.preferences[keyPath: path] = $0 })
    }
    private func profileBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { app.library.profiles.first { $0.id == id }?.name ?? "" }, set: { value in
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let index = app.library.profiles.firstIndex(where: { $0.id == id }) else { return }
            app.library.profiles[index].name = String(value.prefix(80))
        })
    }
    private func clearHistory() {
        let profileID = model.session.profileID
        guard let profile = app.library.profiles.first(where: { $0.id == profileID }) else { return }
        let alert = NSAlert(); alert.messageText = "Clear Neutrino history for \(profile.name)?"; alert.informativeText = "Visits recorded by Neutrino will be removed. Chromium's native history is separate; clear it in Chrome's own controls. Neutrino bookmarks, notes, and other profiles are kept. This cannot be undone."
        alert.addButton(withTitle: "Clear Neutrino history"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !app.terminating, !app.deletingProfileIDs.contains(profileID),
              app.library.profiles.contains(where: { $0.id == profileID }) else { return }
        app.library.history.removeAll { $0.profileID == profileID }
        app.notice = "Neutrino history cleared for \(profile.name)."
    }
    private func clearWebsiteData() {
        guard !model.isPrivate else { app.notice = "Close this private window to discard its temporary website storage."; return }
        let profileID = model.session.profileID
        guard let profile = app.library.profiles.first(where: { $0.id == profileID }) else { return }
        let profileName = profile.name
        let alert = NSAlert(); alert.messageText = "Reset website data and Chromium for \(profileName)?"
        alert.informativeText = "WebKit cookies, caches and local databases will be cleared. Chromium's entire engine profile will be reset, including installed extensions, native bookmarks, history and settings. You will be signed out. Neutrino bookmarks, history, notes and tab addresses are kept. Close other windows using this profile first; unsaved page work may be lost. This cannot be undone."
        alert.addButton(withTitle: "Reset profile storage"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        clearing = true
        Task {
            defer { clearing = false }
            do {
                try await app.requestWebsiteDataClear(profileID)
                let ready = NSAlert(); ready.messageText = "Website data removal is queued for \(profileName)"
                ready.informativeText = "Quit and reopen Neutrino to clear WebKit site data and reset Chromium before either engine loads. Neutrino bookmarks, history, notes and tab addresses are kept; Chromium's engine-local records and extensions will be removed."
                ready.addButton(withTitle: "Quit Neutrino"); ready.addButton(withTitle: "Later")
                if ready.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
            } catch { app.notice = error.localizedDescription }
        }
    }
}
