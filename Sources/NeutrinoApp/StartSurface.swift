import NeutrinoCore
// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct StartSurface: View {
  @ObservedObject var model: BrowserModel
  @EnvironmentObject private var app: AppState
  @Environment(\.browserTheme) private var theme
  let onSearch: () -> Void
  let onCustomize: () -> Void
  var body: some View {
    GeometryReader { viewport in
      ScrollView {
        VStack(alignment: .leading, spacing: 30) {
          HStack {
            Text(
              model.isPrivate
                ? "PRIVATE BROWSING" : Date.now.formatted(.dateTime.weekday(.wide)).uppercased()
            ).font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(theme.tint)
            Spacer()
            Image(systemName: model.isPrivate ? "hand.raised" : "sparkle").foregroundStyle(
              theme.tint.opacity(0.7))
          }
          VStack(alignment: .leading, spacing: 12) {
            Text(model.isPrivate ? "A little privacy.\nA fresh start." : "Room to explore.").font(
              .system(size: min(48, viewport.size.width * 0.08), weight: .medium, design: .rounded)
            ).tracking(-1.5)
            Text(
              model.isPrivate
                ? "Tabs and history won’t be saved. Downloads remain on disk; websites and your network can still see your activity."
                : "Your next idea, project, or rabbit hole starts here."
            ).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(
              horizontal: false, vertical: true)
          }
          Button(action: onSearch) {
            HStack(spacing: 14) {
              Image(systemName: "magnifyingglass").foregroundStyle(theme.tint)
              Text("Search or enter a website").foregroundStyle(.secondary)
              Spacer()
              Text("⌘L").font(.system(size: 11)).foregroundStyle(.tertiary).padding(5).background(
                theme.foreground.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
            }.padding(18).background(
              theme.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 14)
            ).overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.foreground.opacity(0.08)))
          }.buttonStyle(.plain).accessibilityLabel("Search or enter a website")
          if !model.bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
              HStack {
                Text("YOUR BOOKMARKS").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                  .foregroundStyle(.secondary)
                Spacer()
                Button("View all") { model.togglePanel(.bookmarks) }.buttonStyle(.plain).font(
                  .caption
                ).foregroundStyle(theme.tint)
              }
              LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140))], alignment: .leading, spacing: 12
              ) {
                ForEach(Array(model.bookmarks.prefix(8))) { bookmark in
                  Button {
                    model.newTab(url: bookmark.url)
                  } label: {
                    VStack(alignment: .leading, spacing: 18) {
                      Image(systemName: "globe").foregroundStyle(theme.tint).padding(10).background(
                        theme.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                      VStack(alignment: .leading, spacing: 4) {
                        Text(bookmark.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(bookmark.url.host ?? "Website").font(.system(size: 10))
                          .foregroundStyle(.secondary).lineLimit(1)
                      }
                    }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(
                      theme.canvas.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                  }.buttonStyle(.plain)
                }
              }
            }
          } else if !model.isPrivate {
            HStack(alignment: .top, spacing: 14) {
              Image(systemName: "bookmark").foregroundStyle(theme.tint).padding(10).background(
                theme.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
              VStack(alignment: .leading, spacing: 5) {
                Text("Keep the places you love.").font(.system(size: 13, weight: .semibold))
                Text("Press ⌘D on a page to save it, or import your bookmarks in the Library.")
                  .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
              }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(
              theme.canvas.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
          }
          ForEach(Array(app.startWidgets.enumerated()), id: \.offset) { _, widget in
            VStack(alignment: .leading, spacing: 8) {
              Text(widget.widgetTitle ?? "").font(.system(size: 13, weight: .semibold))
              Text(widget.widgetBody ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
              .background(theme.canvas.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
          }
          HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
              Text("Make this space yours.").font(.system(size: 13, weight: .medium))
              Text("A new layout. A different color. Your way.").font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open editor", action: onCustomize).buttonStyle(NeutrinoButtonStyle())
          }
        }.padding(min(56, viewport.size.width * 0.08)).frame(maxWidth: 760).frame(
          maxWidth: .infinity, minHeight: viewport.size.height, alignment: .center
        )
        .background(BrowserLayoutRegion(identifier: "neutrino.startPageContent"))
      }.background(BrowserLayoutRegion(identifier: "neutrino.startPageScroll"))
    }.background(theme.card)
  }
}
