// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import NeutrinoCore

struct BrowserWindowRoot: View {
    @EnvironmentObject private var app: AppState
    let isPrivate: Bool
    @State private var model: BrowserModel?
    @State private var pendingURLs: [URL] = []
    var body: some View {
        Group {
            if app.ready && (!app.library.preferences.completedOnboarding || app.onboardingSaving) && !CommandLine.arguments.contains("--smoke-test") { OnboardingView() }
            else if let model, app.ready { BrowserWindow(model: model) }
            else if let error = app.startupError { StartupRecovery(error: error) }
            else { ProgressView("Opening Neutrino…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(minWidth: 760, minHeight: 520)
        .ignoresSafeArea(.container, edges: .top)
        .disabled(app.finalQuitDataFrozen || app.onboardingSaving)
        .task {
            if !app.ready { await app.load() }
            if app.ready && (model == nil || model?.isClosed == true) { createModel() }
        }
        .onOpenURL { url in
            guard !app.finalQuitDataFrozen, AddressResolver.isWebURL(url) else { return }
            if let model, !model.isClosed {
                // Air Traffic Control sends a site's links to its chosen Space.
                if let site = ContentBlocking.site(url), app.feature("link-routes"), !model.isPrivate,
                   let route = app.library.preferences.linkRoutes?.first(where: { site == $0.host || site.hasSuffix("." + $0.host) }),
                   app.library.spaces?.contains(where: { $0.id == route.spaceID && $0.profileID == model.session.profileID }) == true {
                    if model.session.spaceID != route.spaceID { model.switchSpace(route.spaceID) }
                    model.newTab(url: url)
                }
                // Arc opens links from other apps in a small window first.
                else if model.configuration.theme.preset == "arc" && app.feature("little-arc") { PeekWindow.show(url, model: model) }
                else { model.newTab(url: url) }
            }
            else { pendingURLs.append(url); if app.ready { createModel() } }
        }
        .onChange(of: app.ready) { _, ready in
            if ready && model == nil { createModel() }
        }
        .onChange(of: app.library.preferences.completedOnboarding) { _, complete in
            if complete && model == nil { createModel() }
        }
        .onChange(of: app.onboardingSaving) { _, saving in
            if !saving && app.library.preferences.completedOnboarding && model == nil { createModel() }
        }
        .onChange(of: app.finalQuitDataFrozen) { _, frozen in
            if !frozen && app.ready && (model == nil || model?.isClosed == true) { createModel() }
        }
    }
    private func createModel() {
        guard !app.finalQuitDataFrozen, !app.onboardingSaving, app.library.preferences.completedOnboarding || CommandLine.arguments.contains("--smoke-test") else { return }
        if CommandLine.arguments.contains("--smoke-test") {
            app.library.profiles[0].engineID = .webkit
            if app.library.spaces?.count == 1 && app.library.spaces?[0].tabs.count == 1 && app.library.spaces?[0].tabs[0].url == nil { app.library.spaces?[0].tabs[0].engineID = .webkit }
        }
        let created = BrowserModel(app: app, isPrivate: isPrivate)
        model = created
        for url in pendingURLs { created.newTab(url: url) }
        pendingURLs.removeAll()
    }
}
struct BrowserWindow: View {
    @ObservedObject var model: BrowserModel
    @EnvironmentObject private var app: AppState
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        RustShellView(app: app, model: model, openWindow: { isPrivate in
            openWindow(id: isPrivate ? "private" : "browser")
        })
        .focusedSceneObject(model)
        .background(WindowCloseObserver(model: model))
        .onAppear { model.synchronizeSplit() }
        .onChange(of: model.configuration.layout.split) { _, _ in model.synchronizeSplit() }
    }
}
struct WindowCloseObserver: NSViewRepresentable {
    let model: BrowserModel
    func makeNSView(context: Context) -> ObserverView { ObserverView(model: model) }
    func updateNSView(_ nsView: ObserverView, context: Context) {}
    @MainActor final class ObserverView: NSView {
        let model: BrowserModel
        private var observation: NotificationObservation?
        private var focusObservation: NotificationObservation?
        private var delegateProxy: WindowDelegateProxy?
        init(model: BrowserModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("Not used") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, observation == nil else { return }
            window.title = model.isPrivate ? "Neutrino — Private" : "Neutrino"
            window.isRestorable = false
            let proxy = WindowDelegateProxy(original: window.delegate, model: model)
            delegateProxy = proxy; window.delegate = proxy
            focusObservation = NotificationObservation(NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak model, weak window] _ in
                MainActor.assumeIsolated {
                    guard let window, window.isKeyWindow else { return }
                    model?.updateFocusedTab(window.firstResponder)
                }
            })
            observation = NotificationObservation(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [model] _ in
                Task { @MainActor in model.closeWindow() }
            })
        }
    }
}
extension Notification.Name {
    static let neutrinoFocusAddress = Notification.Name("neutrino.focusAddress")
    static let neutrinoFind = Notification.Name("neutrino.find")
    static let neutrinoOpenBrowserWindow = Notification.Name("neutrino.openBrowserWindow")
    static let neutrinoProfileDeleted = Notification.Name("neutrino.profileDeleted")
}
