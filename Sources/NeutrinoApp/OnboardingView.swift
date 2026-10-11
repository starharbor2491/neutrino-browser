// SPDX-License-Identifier: MPL-2.0
import AppKit
import NeutrinoCore
import SwiftUI

struct OnboardingView: View {
  @EnvironmentObject private var app: AppState
  @State private var step = 0
  @State private var profileName = "Personal"
  @State private var spaceName = "Everyday"
  @State private var configuration = Configuration()
  @State private var search = SearchProvider.duckDuckGo
  @State private var blocking = true
  @State private var popups = true
  @State private var restore = true
  @State private var imported = false
  @State private var defaultBrowserStatus: String?
  @State private var saving = false
  init(previewStep: Int = 0) { _step = State(initialValue: min(7, max(0, previewStep))) }
  private let steps = [
    "Welcome", "Your workspace", "Bring your bookmarks", "Make it yours", "Search & privacy",
    "Your features", "AI, on your terms", "Ready to browse",
  ]
  private var theme: Theme { configuration.theme }
  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 12) {
          NeutrinoMark(size: 38)
          Text("neutrino").font(.system(size: 22, weight: .semibold, design: .rounded))
        }.padding(.bottom, 42)
        ForEach(steps.indices, id: \.self) { index in
          HStack(spacing: 12) {
            ZStack {
              Circle().fill(index == step ? theme.tint : theme.foreground.opacity(0.05))
              if index < step {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                  .foregroundStyle(theme.tint)
              } else {
                Text("\(index + 1)").font(.system(size: 11, weight: .medium)).foregroundStyle(
                  index == step ? Color.white : .secondary)
              }
            }.frame(width: 26, height: 26)
            Text(steps[index]).font(.system(size: 12, weight: index == step ? .semibold : .regular))
              .foregroundStyle(index == step ? theme.foreground : .secondary)
          }.padding(.vertical, 10)
        }
        Spacer()
        Text("A little structure.\nA lot of possibility.").font(
          .system(size: 20, weight: .medium, design: .rounded)
        ).lineSpacing(5)
        Text("Everything starts on your Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
          .padding(.top, 12)
      }.padding(32).frame(width: 264).background(theme.canvas)
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("SET UP YOUR NEUTRINO").font(.system(size: 10, weight: .semibold)).tracking(2)
            .foregroundStyle(theme.tint)
          Spacer()
          Text("\(step + 1) / \(steps.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
        }.padding(.bottom, 26)
        Text(title).font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-1)
          .padding(.bottom, 12)
        Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(
          horizontal: false, vertical: true
        ).padding(.bottom, 26)
        ScrollView {
          stepContent.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
        }
        if let notice = app.notice {
          Text(notice).font(.caption).foregroundStyle(.secondary).padding(.top, 10)
        }
        HStack {
          if step > 0 { Button("Back") { step -= 1 }.buttonStyle(NeutrinoButtonStyle()) }
          Spacer()
          Button(step == steps.count - 1 ? (saving ? "Saving…" : "Open Neutrino") : "Continue") {
            if step == steps.count - 1 { finish() } else { step += 1 }
          }
          .buttonStyle(NeutrinoButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
          .disabled(saving || !validStep)
        }.padding(.top, 20)
      }.padding(42).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.card)
    }.environment(\.browserTheme, theme).tint(theme.tint).preferredColorScheme(theme.scheme)
      .frame(minWidth: 760, minHeight: 560).background(theme.canvas)
  }
  private var validStep: Bool {
    step != 1
      || (!profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !spaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
  private var title: String {
    [
      "Your browser.\nYour space.", "Give your day a home.", "Keep the good stuff.",
      "Find your starting point.", "Quiet by default.", "Built around your day.",
      "You choose the intelligence.", "Make yourself at home.",
    ][step]
  }
  private var subtitle: String {
    [
      "Meet Neutrino: a calm place for the web, with room to make it entirely yours.",
      "Spaces organize your tabs. Profiles keep website accounts and browsing data separate. Add more of either later.",
      "Import an HTML bookmarks export from Safari, Chrome, Firefox, or Opera. Import is optional; website accounts and passwords are not imported here.",
      "Choose a foundation. Every layout, color, and component can be changed in the visual editor.",
      "Choose your search engine and browsing defaults. These settings apply locally and can be changed at any time.",
      "Tabs, split view, bookmarks, history, downloads, profiles, and private browsing are ready in your browser. Optional modules live in the module center.",
      "Use your own API key or a local model endpoint. AI stays off until you configure it, and only receives page content when you ask.",
      "Review your setup, then start browsing. You can return to every choice in Settings or Edit mode.",
    ][step]
  }
  @ViewBuilder private var stepContent: some View {
    switch step {
    case 0:
      VStack(spacing: 12) {
        ChoiceCard(
          title: "A workspace for the web",
          detail: "Spaces, pinned tabs, folders, and split views keep things together.",
          icon: "rectangle.split.2x1", selected: true
        ) {}
        ChoiceCard(
          title: "Make the interface your own",
          detail: "Move controls, change layouts, and save setups for each Space.",
          icon: "slider.horizontal.3", selected: true
        ) {}
        ChoiceCard(
          title: "Local first",
          detail: "Browsing data stays on this Mac. No Neutrino account is required.",
          icon: "desktopcomputer", selected: true
        ) {}
      }
    case 1:
      VStack(alignment: .leading, spacing: 18) {
        input("PROFILE", text: $profileName)
        input("FIRST SPACE", text: $spaceName)
        Text(
          "This Space will use your \(profileName.isEmpty ? "Personal" : profileName) profile for sign-ins, cookies, and extensions."
        ).font(.caption).foregroundStyle(.secondary)
      }
    case 2:
      VStack(alignment: .leading, spacing: 18) {
        ChoiceCard(
          title: imported ? "Bookmarks imported" : "Import a bookmarks file",
          detail: "Select a browser-exported HTML file. Duplicate URLs are skipped.",
          icon: imported ? "checkmark.circle" : "arrow.down.document", selected: imported
        ) { imported = app.importBookmarks(profileID: app.library.profiles[0].id) || imported }
        Text("You can import later from the bookmarks panel.").font(.caption).foregroundStyle(
          .secondary)
      }
    case 3:
      VStack(spacing: 12) {
        ChoiceCard(
          title: "The Neutrino way",
          detail: "Vertical tabs, a calm canvas, and plenty of space for the page.",
          icon: "sidebar.left", selected: configuration.layout.tabs == .leading
        ) {
          configuration.layout.tabs = .leading
          configuration.layout.tabsWidth = 244
          configuration.layout.statusBar = false
        }
        ChoiceCard(
          title: "Familiar, refined", detail: "Horizontal tabs with a compact navigation bar.",
          icon: "rectangle.topthird.inset.filled", selected: configuration.layout.tabs == .top
        ) { configuration.layout.tabs = .top }
        HStack(spacing: 12) {
          ForEach(Accent.allCases, id: \.self) { accent in
            Button {
              configuration.theme.accent = accent
            } label: {
              Circle().fill(accent.color).frame(width: 28, height: 28).overlay(
                Circle().stroke(
                  configuration.theme.accent == accent ? theme.foreground : .clear, lineWidth: 2
                ).padding(-4))
            }.buttonStyle(.plain).help(accent.rawValue.capitalized)
          }
          Spacer()
          Picker("Appearance", selection: $configuration.theme.colorMode) {
            ForEach(ColorMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
          }.frame(width: 140)
        }.padding(12)
      }
    case 4:
      VStack(spacing: 12) {
        ForEach(SearchProvider.allCases, id: \.self) { provider in
          ChoiceCard(
            title: provider.label, detail: "Use \(provider.label) for address-bar searches.",
            icon: "magnifyingglass", selected: search == provider
          ) { search = provider }
        }
        option(
          "Block known ad and tracker domains",
          detail: "Bundled local rules; you can disable blocking in Settings.", value: $blocking)
        option(
          "Block unsolicited popups", detail: "Keep unrequested windows out of your workspace.",
          value: $popups)
      }
    case 5:
      VStack(spacing: 14) {
        option(
          "Pick up where you left off",
          detail: "Restore your regular tabs after reopening. Private browsing stays temporary.",
          value: $restore)
        ChoiceCard(
          title: "Your optional modules",
          detail:
            "Reader, notes, screenshots, focus mode, and resource monitoring can be managed from Modules.",
          icon: "square.stack.3d.up", selected: true
        ) {}
        Text(
          "Chrome extensions run with Blink. WebKit uses a separate website store and does not support Chrome extensions."
        ).font(.caption).foregroundStyle(.secondary)
      }
    case 6:
      AIConfigurationView(compact: true)
    default:
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 14) {
          NeutrinoMark(size: 48)
          VStack(alignment: .leading, spacing: 5) {
            Text(spaceName).font(.title3.bold())
            Text(
              "\(profileName) profile · \(search.label) search · \(configuration.layout.tabs == .leading ? "Vertical" : "Horizontal") tabs"
            ).font(.caption).foregroundStyle(.secondary)
          }
        }
        Button("Make Neutrino your default browser") { setDefaultBrowser() }.buttonStyle(
          NeutrinoButtonStyle())
        if let defaultBrowserStatus {
          Text(defaultBrowserStatus).font(.caption).foregroundStyle(.secondary)
        }
        if !ChromiumRuntime.shared.isInstalled(in: app.dataDirectory) {
          Text(
            "The Blink engine is missing from this development build. Install a complete Neutrino build for Blink browsing, or select WebKit in Settings."
          ).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
  private func input(_ title: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(
        .secondary)
      TextField(title, text: text).textFieldStyle(.plain).font(.system(size: 16)).padding(14)
        .background(theme.canvas, in: RoundedRectangle(cornerRadius: 10))
    }
  }
  private func option(_ title: String, detail: String, value: Binding<Bool>) -> some View {
    ChoiceCard(
      title: title, detail: detail, icon: value.wrappedValue ? "checkmark.shield" : "shield",
      selected: value.wrappedValue
    ) { value.wrappedValue.toggle() }
  }
  private func finish() {
    guard !saving, !app.onboardingSaving, !app.finalQuitDataFrozen else { return }
    saving = true
    app.onboardingSaving = true
    app.library.profiles[0].name = String(
      profileName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    app.library.normalizeSpaces()
    app.library.spaces?[0].name = String(
      spaceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    app.library.preferences.search = search
    app.library.preferences.blockTrackers = blocking
    app.library.preferences.blockPopups = popups
    app.library.preferences.restoreSession = restore
    app.applyConfiguration(configuration)
    Task { @MainActor in
      app.library.preferences.completedOnboarding = true
      if !(await app.flush()) {
        app.library.preferences.completedOnboarding = false
        app.notice = "Setup could not be saved. Try again."
      }
      saving = false
      app.onboardingSaving = false
    }
  }
  private func setDefaultBrowser() {
    NSWorkspace.shared.setDefaultApplication(
      at: Bundle.main.bundleURL, toOpenURLsWithScheme: "https"
    ) { error in
      Task { @MainActor in
        if let error {
          defaultBrowserStatus = error.localizedDescription
          return
        }
        NSWorkspace.shared.setDefaultApplication(
          at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http"
        ) { error in
          Task { @MainActor in
            defaultBrowserStatus =
              error?.localizedDescription ?? "Neutrino is your default browser."
          }
        }
      }
    }
  }
}
