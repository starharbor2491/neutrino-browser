// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI

struct StartupRecovery: View {
    @EnvironmentObject private var app: AppState
    let error: String
    @State private var resetting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "lifepreserver").font(.system(size: 36)).foregroundStyle(Color.accentColor)
            Text("Let's get Neutrino open.").font(.largeTitle.weight(.semibold))
            Text("Your saved data could not be opened. It has not been deleted.").foregroundStyle(.secondary)
            Text(error).font(.callout).textSelection(.enabled).padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Try again") { Task { await app.load() } }
                Button("Show data folder") { NSWorkspace.shared.open(app.dataDirectory) }
                Button(resetting ? "Recovering…" : "Start with a fresh library…") {
                    if confirm("Start with a fresh library?", "Neutrino will move the old database into a Recovery folder without deleting it. The new library will not contain your saved tabs, bookmarks, notes, or profile definitions. Website storage is left untouched.") {
                        resetting = true; Task { await app.resetLibrary(); resetting = false }
                    }
                }.disabled(resetting)
            }
        }.padding(48).frame(maxWidth: 740).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
@MainActor
func confirm(_ title: String, _ detail: String) -> Bool {
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
    alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}
