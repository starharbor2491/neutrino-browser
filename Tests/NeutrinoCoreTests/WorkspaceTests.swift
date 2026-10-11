// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import NeutrinoCore

@Test func recreatedSpacesAndArchivedBlankTabsKeepTheChosenEngine() throws {
  var state = LibraryState()
  state.profiles[0].engineID = .webkit
  state.spaces = nil
  state.normalizeSpaces()
  var space = try #require(state.spaces?.first)
  #expect(space.tabs[0].engineID == .webkit)
  let original = space.tabs[0].id
  space.tabs[0].lastUsedAt = Date(timeIntervalSince1970: 0)
  space.archiveIdleTabs(before: Date())
  #expect(space.archivedTabs.first?.id == original)
  #expect(space.tabs[0].engineID == .webkit)
}

@Test func spacesShareProfilesButKeepOrganizationAndSetupsSeparate() throws {
  var state = LibraryState()
  let profile = state.profiles[0].id
  var work = BrowserSpace(name: "Work", profileID: profile)
  let personal = BrowserSpace(name: "Personal", profileID: profile)
  var custom = Configuration()
  custom.layout.tabs = .trailing
  let setup = NamedConfiguration(name: "Work setup", configuration: custom)
  work.setupID = setup.id
  state.spaces = [work, personal]
  state.preferences.savedConfigurations = [setup]
  state.normalize()
  let normalized = state
  state.normalize()
  #expect(state == normalized)
  #expect(state.configuration(for: work.id).layout.tabs == .trailing)
  #expect(state.configuration(for: personal.id).layout.tabs == .leading)
  #expect(state.spaces?[0].profileID == state.spaces?[1].profileID)
  #expect(try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state)) == state)
}
@Test func liveTabOwnershipMovesWithoutDuplicatingOrReleasingAnotherWindowsClaim() {
  var ownership = LiveTabOwnership()
  let tab = UUID()
  let first = UUID()
  let second = UUID()
  #expect(ownership.claim(tab, in: first) == nil)
  #expect(ownership.claim(tab, in: second) == first)
  ownership.release(tab, from: first)
  #expect(ownership.owner(of: tab) == second)
  ownership.release(tab, from: second)
  #expect(ownership.owner(of: tab) == nil)
}
@Test func normalizedSpacesCannotShareATabIdentityAcrossProfiles() throws {
  var state = LibraryState()
  let other = Profile(name: "Other")
  state.profiles.append(other)
  let parent = BrowserTab()
  let child = BrowserTab(parentID: parent.id)
  let first = BrowserSpace(
    name: "Personal", profileID: state.profiles[0].id, tabs: [parent, child])
  let second = BrowserSpace(name: "Work", profileID: other.id, tabs: [parent, child])
  state.spaces = [first, second]
  state.normalize()
  let spaces = try #require(state.spaces)
  #expect(Set(spaces.flatMap { $0.tabs.map(\.id) }).count == 4)
  #expect(spaces[1].tabs[1].parentID == spaces[1].tabs[0].id)
  let normalized = state
  state.normalize()
  #expect(state == normalized)
}
@Test func profileDeletionReconnectsAffectedWindowsToAValidSharedSpace() throws {
  var state = LibraryState()
  let removed = state.profiles[0].id
  let retained = Profile(name: "Work")
  state.profiles.append(retained)
  let work = BrowserSpace(name: "Work", profileID: retained.id)
  state.spaces?.append(work)
  var session = WindowSession(profileID: removed)
  session.spaceID = state.spaces?[0].id
  state.sessions = [session]
  let saved = try state.removeProfile(removed, replacingWith: retained.id)
  #expect(state.sessions[0].spaceID == work.id)
  #expect(state.sessions[0].tabs == work.tabs)
  #expect(!((state.spaces ?? []).contains { $0.profileID == removed }))
  state.restoreProfile(saved)
  #expect(state.sessions[0] == session)
  #expect((state.spaces ?? []).contains { $0.profileID == removed })
}
@Test func archiveProtectsPinnedAndFolderTabsAndCanRecoverRegularTabs() {
  var space = BrowserSpace(name: "Work", profileID: UUID())
  let folder = TabFolder(name: "Projects")
  space.folders = [folder]
  var regular = BrowserTab(url: URL(string: "https://example.com"))
  regular.lastUsedAt = .distantPast
  var pinned = regular
  pinned.id = UUID()
  pinned.pinned = true
  var filed = regular
  filed.id = UUID()
  filed.folderID = folder.id
  space.tabs = [regular, pinned, filed]
  space.archiveIdleTabs(before: Date())
  #expect(space.archivedTabs.map(\.id) == [regular.id])
  #expect(space.tabs.map(\.id) == [pinned.id, filed.id])
  let restored = space.restoreArchivedTab(regular.id)
  let restoredAgain = space.restoreArchivedTab(regular.id)
  #expect(restored)
  #expect(!restoredAgain)
}
@Test func blockerUsesHostBoundariesAndNeverBlocksTopLevelNavigation() {
  #expect(ContentBlocking.blocks(URL(string: "https://ads.doubleclick.net/ad")!))
  #expect(!ContentBlocking.blocks(URL(string: "https://doubleclick.net/ad")!, topLevel: true))
  #expect(!ContentBlocking.blocks(URL(string: "https://notdoubleclick.net")!))
  #expect(!ContentBlocking.blocks(URL(string: "https://example.com/doubleclick.net")!))
}
@Test func remoteAIKeysCannotBeRedirectedToOtherHostsOrInsecureEndpoints() throws {
  #expect(throws: ValidationError.self) {
    try AIConfiguration(provider: .openAI, endpoint: "https://evil.example/v1", model: "model")
      .validatedEndpoint()
  }
  #expect(throws: ValidationError.self) {
    try AIConfiguration(provider: .local, endpoint: "http://192.168.1.2/v1", model: "model")
      .validatedEndpoint()
  }
  #expect(
    try AIConfiguration(provider: .local, endpoint: "http://localhost:1234/v1", model: "model")
      .validatedEndpoint().host == "localhost")
}
@Test func organizationProposalsCannotMoveForeignOrDuplicateTabs() throws {
  let id = UUID()
  let outside = UUID()
  func proposal(_ ids: [UUID]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "folders": [["name": "Work", "tabIDs": ids.map(\.uuidString)]]
    ])
  }
  #expect(throws: ValidationError.self) {
    try TabOrganization.decode(proposal([outside]), knownTabs: [id])
  }
  #expect(throws: ValidationError.self) {
    try TabOrganization.decode(proposal([id, id]), knownTabs: [id])
  }
  var space = BrowserSpace(name: "Work", profileID: UUID(), tabs: [BrowserTab(id: id)])
  let decoded = try TabOrganization.decode(proposal([id]), knownTabs: [id])
  try decoded.apply(to: &space)
  #expect(space.tabs[0].id == id)
  #expect(space.tabs[0].folderID == space.folders[0].id)
}
