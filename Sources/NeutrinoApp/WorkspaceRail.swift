import NeutrinoCore
// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct WorkspaceRail<Row: View>: View {
  @ObservedObject var model: BrowserModel
  @EnvironmentObject private var app: AppState
  @Environment(\.browserTheme) private var theme
  let newTab: () -> Void
  @ViewBuilder var row: (BrowserTab) -> Row
  @State private var spaceName = ""
  @State private var addingSpace = false
  @State private var folderName = ""
  @State private var addingFolder = false
  private var tabs: [BrowserTab] { model.session.tabs }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        Image(
          systemName: model.isPrivate ? "hand.raised" : model.space?.symbol ?? "circle.grid.2x2"
        ).foregroundStyle(theme.tint)
        Text(model.isPrivate ? "Private" : model.space?.name ?? "Personal").font(
          .system(size: 15, weight: .semibold))
        Spacer()
        Menu {
          Button("New Space") { addingSpace = true }
          Button("New folder") { addingFolder = true }
          Button("Edit this Space’s setup") { model.sheet = .customize }
          if let space = model.space, !space.archivedTabs.isEmpty {
            Menu("Archived tabs") {
              ForEach(space.archivedTabs) { tab in
                Button(tab.title) { app.restoreArchivedTab(tab.id, spaceID: space.id) }
              }
            }
          }
        } label: {
          Image(systemName: "ellipsis").frame(width: 24, height: 24)
        }.menuStyle(.borderlessButton).fixedSize()
      }.padding(.horizontal, 14)
      Button(action: newTab) {
        HStack {
          Image(systemName: "plus")
          Text("New tab")
          Spacer()
          Text("⌘T").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .font(.system(size: 13)).padding(12).background(
          theme.foreground.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
      }.buttonStyle(.plain).padding(.horizontal, 10)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 5) {
          if tabs.contains(where: \.pinned) {
            sectionLabel("PINNED")
            ForEach(tabs.filter(\.pinned)) { row($0) }
            Rectangle().fill(theme.foreground.opacity(0.08)).frame(height: 1).padding(.vertical, 10)
          }
          ForEach(model.space?.folders ?? []) { folder in
            Button {
              app.toggleFolder(folder.id, spaceID: model.session.spaceID)
            } label: {
              HStack(spacing: 8) {
                Image(systemName: folder.collapsed ? "chevron.right" : "chevron.down").font(
                  .system(size: 9, weight: .semibold))
                Image(systemName: "folder")
                Text(folder.name)
                Spacer()
                Text("\(tabs.filter { $0.folderID == folder.id }.count)").foregroundStyle(.tertiary)
              }
              .font(.system(size: 12, weight: .medium)).padding(10)
            }.buttonStyle(.plain)
              .dropDestination(for: String.self) { values, _ in
                guard let text = values.first, let id = UUID(uuidString: text),
                  let i = model.session.tabs.firstIndex(where: { $0.id == id })
                else { return false }
                model.session.tabs[i].folderID = folder.id
                return true
              }
            if !folder.collapsed {
              ForEach(tabs.filter { $0.folderID == folder.id && !$0.pinned }) {
                row($0).padding(.leading, 10)
              }
            }
          }
          sectionLabel("TODAY")
          ForEach(tabs.filter { !$0.pinned && $0.folderID == nil }) { row($0) }
        }.padding(.horizontal, 7)
      }
      Spacer(minLength: 0)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 5) {
          ForEach(app.library.spaces ?? []) { space in
            Button {
              model.switchSpace(space.id)
            } label: {
              Image(systemName: space.symbol).font(.system(size: 14)).frame(width: 30, height: 30)
                .background(
                  space.id == model.session.spaceID ? theme.tint.opacity(0.15) : .clear,
                  in: RoundedRectangle(cornerRadius: 8)
                )
                .foregroundStyle(space.id == model.session.spaceID ? theme.tint : .secondary)
            }.buttonStyle(.plain).help(space.name).accessibilityLabel("Switch to \(space.name)")
              .disabled(model.isPrivate)
          }
          Spacer(minLength: 0)
          IconButton(title: "New Space", icon: "plus") { addingSpace = true }.disabled(
            model.isPrivate)
        }
      }.padding(.horizontal, 10)
      HStack {
        Image(systemName: "person.crop.circle.fill").font(.system(size: 20)).foregroundStyle(
          theme.tint.opacity(0.75))
        VStack(alignment: .leading, spacing: 3) {
          Text(model.profile.name).font(.system(size: 12, weight: .semibold))
          Text(model.isPrivate ? "Temporary browsing" : "Local profile").font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        Spacer()
        IconButton(title: "Library", icon: "tray") { model.togglePanel(.bookmarks) }
      }.padding(12).background(
        theme.foreground.opacity(0.04), in: RoundedRectangle(cornerRadius: 12)
      ).padding(.horizontal, 10)
    }.padding(.vertical, 12)
      .popover(isPresented: $addingSpace) {
        VStack(alignment: .leading, spacing: 14) {
          Text("Create a Space").font(.headline)
          Text("Uses your \(model.profile.name) profile. Website sign-ins stay available.").font(
            .caption
          ).foregroundStyle(.secondary)
          TextField("Space name", text: $spaceName).textFieldStyle(.plain).padding(10).background(
            theme.card, in: RoundedRectangle(cornerRadius: 8))
          Button("Create Space") {
            if let id = app.createSpace(name: spaceName, profileID: model.profile.id) {
              model.switchSpace(id)
              spaceName = ""
              addingSpace = false
            }
          }.buttonStyle(NeutrinoButtonStyle(prominent: true)).disabled(
            spaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(22).frame(width: 300).background(theme.canvas)
      }
      .popover(isPresented: $addingFolder) {
        VStack(alignment: .leading, spacing: 14) {
          Text("Create a folder").font(.headline)
          TextField("Folder name", text: $folderName)
          Button("Create folder") {
            app.createFolder(name: folderName, spaceID: model.session.spaceID)
            folderName = ""
            addingFolder = false
          }.buttonStyle(NeutrinoButtonStyle(prominent: true)).disabled(
            folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(22).frame(width: 280).background(theme.canvas)
      }
  }
  private func sectionLabel(_ title: String) -> some View {
    Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.tertiary)
      .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 5)
  }
}

@MainActor extension AppState {
  func applyConfiguration(_ configuration: Configuration, to spaceID: UUID?) {
    guard let spaceID, let index = library.spaces?.firstIndex(where: { $0.id == spaceID }) else {
      applyConfiguration(configuration)
      return
    }
    var configuration = configuration
    configuration.normalize()
    if let setupID = library.spaces?[index].setupID,
      let setupIndex = library.preferences.savedConfigurations.firstIndex(where: {
        $0.id == setupID
      })
    {
      library.preferences.savedConfigurations[setupIndex].configuration = configuration
    } else {
      let setup = NamedConfiguration(
        name: (library.spaces?[index].name ?? "Space") + " setup", configuration: configuration)
      library.preferences.savedConfigurations.append(setup)
      library.spaces?[index].setupID = setup.id
    }
    windows.values.compactMap(\.model).filter { $0.session.spaceID == spaceID }.forEach {
      $0.synchronizeSplit(force: true)
    }
  }
  func recordBackgroundTab(
    _ tab: BrowserEngineTab, id: UUID, spaceID: UUID?, profileID: UUID, finished: Bool
  ) {
    guard !finalQuitDataFrozen,
      let s = library.spaces?.firstIndex(where: { $0.id == spaceID && $0.profileID == profileID }),
      let i = library.spaces?[s].tabs.firstIndex(where: { $0.id == id })
    else { return }
    if let pages = tab.chromiumSessionPages {
      library.spaces?[s].tabs[i].chromiumPages = tab.isShowingStartPage && pages.count == 1 ? nil : ChromiumSessionPage.normalized(pages)
    }
    let url = tab.isShowingStartPage ? nil : tab.url
    if url == nil || url.map(AddressResolver.isWebURL) == true {
      library.spaces?[s].tabs[i].url = url
      library.spaces?[s].tabs[i].title = boundedPageTitle(tab.title ?? url?.host ?? "New tab")
      if finished, let url {
        addHistory(url: url, title: tab.title ?? url.host ?? "Website", profileID: profileID)
      }
    }
    if let tabs = library.spaces?[s].tabs {
      windows.values.compactMap(\.model).filter { $0.session.spaceID == spaceID }.forEach {
        $0.receiveSharedTabs(tabs)
      }
    }
  }
  func closeBackgroundTab(_ id: UUID, spaceID: UUID) {
    guard !finalQuitDataFrozen, let index = library.spaces?.firstIndex(where: { $0.id == spaceID }),
      var space = library.spaces?[index], let tab = space.tabs.first(where: { $0.id == id })
    else { return }
    if let owner = tabOwnership.owner(of: id) {
      windows[owner]?.model?.takeLiveTab(id)?.dispose()
      tabOwnership.release(id, from: owner)
    }
    for i in space.tabs.indices where space.tabs[i].parentID == id {
      space.tabs[i].parentID = tab.parentID
    }
    space.tabs.removeAll { $0.id == id }
    if space.tabs.isEmpty {
      let engine =
        library.profiles.first(where: { $0.id == space.profileID })?.engineID ?? .chromium
      space.tabs = [BrowserTab(engineID: engine)]
    }
    space.normalize()
    library.spaces?[index] = space
    windows.values.compactMap(\.model).filter { $0.session.spaceID == spaceID }.forEach {
      $0.receiveSharedTabs(space.tabs)
    }
  }
  @discardableResult func createSpace(name: String, profileID: UUID) -> UUID? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !finalQuitDataFrozen, !name.isEmpty,
      library.profiles.contains(where: { $0.id == profileID }), (library.spaces?.count ?? 0) < 100
    else { return nil }
    let engine = library.profiles.first(where: { $0.id == profileID })?.engineID ?? .chromium
    let space = BrowserSpace(
      name: String(name.prefix(80)), profileID: profileID, tabs: [BrowserTab(engineID: engine)])
    library.spaces = (library.spaces ?? []) + [space]
    return space.id
  }
  func createFolder(name: String, spaceID: UUID?) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !finalQuitDataFrozen, !name.isEmpty,
      let i = library.spaces?.firstIndex(where: { $0.id == spaceID }),
      (library.spaces?[i].folders.count ?? 100) < 100
    else { return }
    library.spaces?[i].folders.append(TabFolder(name: String(name.prefix(80))))
  }
  func toggleFolder(_ id: UUID, spaceID: UUID?) {
    guard !finalQuitDataFrozen, let i = library.spaces?.firstIndex(where: { $0.id == spaceID }),
      let f = library.spaces?[i].folders.firstIndex(where: { $0.id == id })
    else { return }
    library.spaces?[i].folders[f].collapsed.toggle()
  }
  func restoreArchivedTab(_ id: UUID, spaceID: UUID) {
    guard !finalQuitDataFrozen, let i = library.spaces?.firstIndex(where: { $0.id == spaceID }),
      library.spaces?[i].restoreArchivedTab(id) == true, let tabs = library.spaces?[i].tabs
    else { return }
    windows.values.compactMap(\.model).filter { $0.session.spaceID == spaceID }.forEach {
      $0.receiveSharedTabs(tabs)
    }
  }
}
