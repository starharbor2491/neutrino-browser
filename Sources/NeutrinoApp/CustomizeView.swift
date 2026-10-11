import NeutrinoCore
// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct CustomizeView: View {
  var model: BrowserModel?
  @EnvironmentObject private var app: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var draft = Configuration()
  @State private var undo: [Configuration] = []
  @State private var selected = "tabs"
  @State private var scopeToSpace = false
  @State private var setupName = "My setup"
  @State private var advanced = false
  @State private var initialized = false
  @State private var resizeWidth: Double?
  @State private var requirements: [String] = []
  @State private var previewID = UUID()
  private var theme: Theme { draft.theme }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        NeutrinoMark(size: 28)
        VStack(alignment: .leading, spacing: 4) {
          Text("Make it yours").font(.system(size: 20, weight: .semibold, design: .rounded))
          Text("Drag a component into a region. Select it to change its appearance.").font(
            .system(size: 12)
          ).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Advanced") { advanced = true }.buttonStyle(NeutrinoButtonStyle())
        IconButton(title: "Exit editor", icon: "xmark") { exit() }.keyboardShortcut(.cancelAction)
      }.padding(22)
      Rectangle().fill(theme.foreground.opacity(0.08)).frame(height: 1)
      HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 16) {
          caption("COMPONENTS")
          component("tabs", title: "Tabs", icon: "rectangle.stack")
          component("navigation", title: "Address & navigation", icon: "magnifyingglass")
          component("bookmarks", title: "Bookmarks bar", icon: "bookmark")
          component("panel", title: "Library panel", icon: "sidebar.left")
          Text("Site identity, permission prompts, and recovery remain accessible in every setup.")
            .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).padding(.top, 14)
          Spacer()
          Button("Restore defaults") { change { $0 = Configuration() } }.buttonStyle(
            NeutrinoButtonStyle())
        }.padding(20).frame(width: 202).background(theme.card)
        VStack(spacing: 18) {
          HStack {
            caption("LIVE LAYOUT PREVIEW")
            Spacer()
            Text("Drop into a highlighted region").font(.system(size: 10)).foregroundStyle(
              .secondary)
          }
          canvas
          HStack(spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(theme.tint)
            Text("The address bar always preserves clear website identity.").font(.system(size: 11))
              .foregroundStyle(.secondary)
            Spacer()
          }
          Spacer(minLength: 0)
        }.padding(24).frame(maxWidth: .infinity).background(theme.canvas)
        inspector.padding(20).frame(width: 238).background(theme.card)
      }
      Rectangle().fill(theme.foreground.opacity(0.08)).frame(height: 1)
      HStack {
        Button("Undo") { if let previous = undo.popLast() { draft = previous } }.buttonStyle(
          NeutrinoButtonStyle()
        ).disabled(undo.isEmpty)
        if model?.space != nil {
          Toggle("Apply to this Space", isOn: $scopeToSpace).toggleStyle(.switch).font(.caption)
            .padding(.leading, 10)
        }
        Spacer()
        Button("Cancel") { exit() }.buttonStyle(NeutrinoButtonStyle())
        Button("Save setup") { save() }.buttonStyle(NeutrinoButtonStyle(prominent: true))
          .keyboardShortcut(.defaultAction)
      }.padding(20).background(theme.card)
    }.frame(width: 1040, height: 690).environment(\.browserTheme, theme).tint(theme.tint)
      .preferredColorScheme(theme.scheme)
      .onAppear {
        guard !initialized else { return }
        draft = model?.configuration ?? app.configuration
        scopeToSpace = model?.space?.setupID != nil
        requirements = app.configurationModuleRequirements
        initialized = true
        app.beginConfigurationPreview(draft, owner: previewID)
      }
      .onChange(of: draft) { _, value in app.updateConfigurationPreview(value, owner: previewID) }
      .onDisappear { app.endConfigurationPreview(owner: previewID) }
      .sheet(
        isPresented: $advanced,
        onDismiss: { app.beginConfigurationPreview(draft, owner: previewID) }
      ) {
        AdvancedSetupView(initialConfiguration: draft) { configuration, modules in
          change { $0 = configuration }
          requirements = modules
        }
      }
  }
  private var canvas: some View {
    VStack(spacing: 5) {
      dock("top", label: "TOP") {
        VStack(spacing: 4) {
          if draft.layout.tabs == .top && draft.layout.hideTabStrip != true {
            previewTabs(vertical: false)
          }
          if draft.layout.navigation == .top { previewAddress }
          if draft.layout.bookmarksBar { previewBookmarks }
        }
      }
      HStack(spacing: 5) {
        dock("left", label: "LEFT") {
          if draft.layout.tabs == .leading && draft.layout.hideTabStrip != true {
            previewTabs(vertical: true)
          }
        }
        .frame(width: max(78, (draft.layout.tabsWidth ?? 244) * 0.45))
        .overlay(alignment: .trailing) {
          Rectangle().fill(theme.tint.opacity(0.3)).frame(width: 4).contentShape(Rectangle())
            .gesture(
              DragGesture().onChanged { value in
                if resizeWidth == nil {
                  resizeWidth = draft.layout.tabsWidth ?? 244
                  undo.append(draft)
                }
                draft.layout.tabsWidth = min(
                  320, max(140, (resizeWidth ?? 244) + value.translation.width * 2))
              }.onEnded { _ in resizeWidth = nil })
        }
        VStack(spacing: 14) {
          Image(systemName: "globe").font(.system(size: 30)).foregroundStyle(
            theme.tint.opacity(0.4))
          Text("Your page").font(.system(size: 18, weight: .medium, design: .rounded))
          Text("The web gets the room it deserves.").font(.system(size: 11)).foregroundStyle(
            .secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(
          theme.card, in: RoundedRectangle(cornerRadius: draft.theme.cornerRadius))
        dock("right", label: "RIGHT") {
          if draft.layout.tabs == .trailing && draft.layout.hideTabStrip != true {
            previewTabs(vertical: true)
          }
          if draft.layout.secondaryPanel != nil {
            tile("panel", title: "Library", icon: "sidebar.right")
          }
        }.frame(width: 88)
      }.frame(minHeight: 260)
      dock("bottom", label: "BOTTOM") {
        VStack(spacing: 4) {
          if draft.layout.navigation == .bottom { previewAddress }
          if draft.layout.tabs == .bottom && draft.layout.hideTabStrip != true {
            previewTabs(vertical: false)
          }
        }
      }
    }.padding(10).background(
      theme.foreground.opacity(0.035), in: RoundedRectangle(cornerRadius: 18)
    ).overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.foreground.opacity(0.08)))
  }
  private var previewAddress: some View {
    tile("navigation", title: "example.com  ·  Website identity", icon: "lock")
  }
  private var previewBookmarks: some View {
    tile("bookmarks", title: "Bookmarks", icon: "bookmark")
  }
  private func previewTabs(vertical: Bool) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      tile("tabs", title: vertical ? "Your tabs" : "Tab 1     Tab 2     +", icon: "rectangle.stack")
      if vertical {
        Text("Pinned\n\nToday\nA little inspiration\nA new idea").font(.system(size: 10))
          .foregroundStyle(.secondary).lineSpacing(8).padding(10)
      }
    }
  }
  private func dock<Content: View>(_ id: String, label: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(spacing: 6) {
      Text(label).font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.tertiary)
      content()
    }.padding(8).frame(maxWidth: .infinity, minHeight: 45).background(
      theme.tint.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)
    ).overlay(
      RoundedRectangle(cornerRadius: 10).stroke(
        theme.tint.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    )
    .dropDestination(for: String.self) { items, _ in
      guard let item = items.first else { return false }
      return dock(item, in: id)
    }
  }
  private func tile(_ id: String, title: String, icon: String) -> some View {
    Button {
      selected = id
    } label: {
      HStack(spacing: 6) {
        Image(systemName: icon)
        Text(title).lineLimit(1)
        Spacer(minLength: 0)
      }.font(.system(size: 10)).padding(9).background(
        theme.card, in: RoundedRectangle(cornerRadius: 8)
      ).overlay(
        RoundedRectangle(cornerRadius: 8).stroke(
          selected == id ? theme.tint : .clear, lineWidth: 1.5))
    }.buttonStyle(.plain).draggable(id)
  }
  private func component(_ id: String, title: String, icon: String) -> some View {
    Button {
      selected = id
    } label: {
      HStack(spacing: 10) {
        Image(systemName: icon).frame(width: 18).foregroundStyle(theme.tint)
        Text(title).font(.system(size: 12))
        Spacer()
        Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(.tertiary)
      }.padding(12).background(
        selected == id ? theme.tint.opacity(0.1) : theme.canvas,
        in: RoundedRectangle(cornerRadius: 10))
    }.buttonStyle(.plain).draggable(id)
  }
  private var inspector: some View {
    VStack(alignment: .leading, spacing: 18) {
      caption("INSPECTOR")
      Text(selected == "navigation" ? "Address & navigation" : selected.capitalized).font(
        .system(size: 16, weight: .semibold, design: .rounded))
      TextField("Setup name", text: $setupName).textFieldStyle(.plain).padding(10).background(
        theme.canvas, in: RoundedRectangle(cornerRadius: 8))
      Text("Accent").font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 10) {
        ForEach(Accent.allCases, id: \.self) { accent in
          Button {
            change {
              $0.theme.accent = accent
              $0.theme.accentHex = nil
            }
          } label: {
            Circle().fill(accent.color).frame(width: 23, height: 23).overlay(
              Circle().stroke(theme.accent == accent ? theme.foreground : .clear, lineWidth: 1)
                .padding(-3))
          }.buttonStyle(.plain).help(accent.rawValue.capitalized)
        }
      }
      Picker(
        "Appearance",
        selection: Binding(
          get: { draft.theme.colorMode }, set: { value in change { $0.theme.colorMode = value } })
      ) { ForEach(ColorMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
      Text("Corner radius · \(Int(draft.theme.cornerRadius)) pt").font(.caption).foregroundStyle(
        .secondary)
      Slider(
        value: Binding(
          get: { draft.theme.cornerRadius },
          set: { value in change { $0.theme.cornerRadius = value } }), in: 0...24)
      Picker(
        "Density",
        selection: Binding(
          get: { draft.theme.density }, set: { value in change { $0.theme.density = value } })
      ) { ForEach(Density.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
      if selected == "tabs" {
        ChoiceCard(
          title: "List tabs", detail: "A simple ordered list.", icon: "list.bullet",
          selected: draft.layout.treeTabs != true
        ) { change { $0.layout.treeTabs = false } }
        ChoiceCard(
          title: "Tree tabs", detail: "Nest related pages.", icon: "list.bullet.indent",
          selected: draft.layout.treeTabs == true
        ) {
          change {
            $0.layout.treeTabs = true
            $0.layout.tabs = .leading
          }
        }
      }
      if selected != "navigation" {
        Button("Remove from layout") {
          change { config in
            switch selected {
            case "tabs": config.layout.hideTabStrip = true
            case "bookmarks": config.layout.bookmarksBar = false
            case "panel": config.layout.secondaryPanel = nil
            default: break
            }
          }
        }.buttonStyle(NeutrinoButtonStyle())
      }
      Spacer()
      Text("⌘, opens Settings. Escape exits editing. Recovery can always restore a working setup.")
        .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
    }
  }
  private func caption(_ text: String) -> some View {
    Text(text).font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
  }
  private func change(_ update: (inout Configuration) -> Void) {
    undo.append(draft)
    if undo.count > 50 { undo.removeFirst() }
    update(&draft)
    draft.normalize()
  }
  private func dock(_ item: String, in region: String) -> Bool {
    guard ["tabs", "navigation", "bookmarks", "panel"].contains(item) else { return false }
    if item == "navigation" && !["top", "bottom"].contains(region) { return false }
    if item == "bookmarks" && region != "top" { return false }
    if item == "panel" && !["left", "right"].contains(region) { return false }
    change { config in
      switch item {
      case "tabs":
        config.layout.hideTabStrip = false
        config.layout.tabs =
          region == "top"
          ? .top : region == "bottom" ? .bottom : region == "left" ? .leading : .trailing
        if region == "top" || region == "bottom" { config.layout.treeTabs = false }
      case "navigation": config.layout.navigation = region == "top" ? .top : .bottom
      case "bookmarks": config.layout.bookmarksBar = true
      case "panel":
        config.layout.secondaryPanel = "bookmarks"
        config.layout.sidebar = region == "left" ? .trailing : .leading
      default: break
      }
    }
    selected = item
    return true
  }
  private func save() {
    app.perform {
      let current = app.library.preferences.configuration
      if try app.applySetup(draft, requirements: requirements) {
        if scopeToSpace, let spaceID = model?.session.spaceID,
          let index = app.library.spaces?.firstIndex(where: { $0.id == spaceID })
        {
          let setup = NamedConfiguration(name: String(setupName.prefix(100)), configuration: draft)
          var saved = setup
          saved.requiredModuleIDs = requirements
          app.library.preferences.savedConfigurations.append(saved)
          app.library.spaces?[index].setupID = saved.id
          app.applyConfiguration(current)
        }
        exit()
      }
    }
  }
  private func exit() {
    app.endConfigurationPreview(owner: previewID)
    dismiss()
  }
}
