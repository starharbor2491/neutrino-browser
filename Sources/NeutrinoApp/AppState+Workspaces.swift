// SPDX-License-Identifier: MPL-2.0
import Foundation
import NeutrinoCore

@MainActor extension AppState {
  @discardableResult func applyConfiguration(_ configuration:Configuration,to spaceID:UUID?) -> Bool {
    guard let spaceID, library.spaces?.contains(where:{$0.id==spaceID})==true else {applyConfiguration(configuration);return true}
    do {
      library=try RustCore.decode(LibraryState.self,from:RustCore.request(["op":"applySpaceConfiguration","value":RustCore.encoded(library),"id":spaceID.uuidString,"configuration":RustCore.encoded(configuration)]))
      windows.values.compactMap(\.model).filter{$0.session.spaceID==spaceID}.forEach{$0.synchronizeSplit(force:true)}
      return true
    } catch {notice=error.localizedDescription;return false}
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
      if finished, let url { tab.updateSiteIcon(for: url) }
      library.spaces?[s].tabs[i].faviconDataURL = tab.faviconDataURL
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
  func createFolder(name: String, spaceID: UUID?, parentID: UUID? = nil) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !finalQuitDataFrozen, !name.isEmpty,
      let i = library.spaces?.firstIndex(where: { $0.id == spaceID }),
      (library.spaces?[i].folders.count ?? 100) < 100
    else { return }
    var folder = TabFolder(name: String(name.prefix(80)))
    if let parentID, let folders = library.spaces?[i].folders, Self.folderDepth(parentID, in: folders).map({ $0 < Self.maxFolderDepth }) == true {
      folder.parentID = parentID
    }
    library.spaces?[i].folders.append(folder)
  }
  /// Ancestors a folder may have; matches the interface's limit.
  static let maxFolderDepth = 3
  /// A folder's number of ancestors, or nil when it's missing or its parents loop.
  static func folderDepth(_ id: UUID, in folders: [TabFolder]) -> Int? {
    var current = id
    for depth in 0...maxFolderDepth + 1 {
      guard let folder = folders.first(where: { $0.id == current }) else { return nil }
      guard let parent = folder.parentID, folders.contains(where: { $0.id == parent }) else { return depth }
      current = parent
    }
    return nil
  }
  /// Moves a folder into another one, or to the top level when `parentID` is nil.
  func nestFolder(_ id: UUID, parentID: UUID?, spaceID: UUID?) {
    guard !finalQuitDataFrozen, let i = library.spaces?.firstIndex(where: { $0.id == spaceID }),
      var folders = library.spaces?[i].folders, let index = folders.firstIndex(where: { $0.id == id })
    else { return }
    if let parentID {
      // The new parent can't be the folder or inside it, and the deepest subfolder must stay within the limit.
      func height(_ folder: UUID, _ level: Int) -> Int {
        level > Self.maxFolderDepth ? 1 : 1 + (folders.filter { $0.parentID == folder }.map { height($0.id, level + 1) }.max() ?? 0)
      }
      var ancestor: UUID? = parentID
      for _ in 0...Self.maxFolderDepth + 1 {
        guard let current = ancestor else { break }
        if current == id { return }
        ancestor = folders.first(where: { $0.id == current })?.parentID
      }
      guard let depth = Self.folderDepth(parentID, in: folders), depth + height(id, 0) <= Self.maxFolderDepth else { return }
    }
    folders[index].parentID = parentID
    library.spaces?[i].folders = folders
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
