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
        .disabled(app.finalQuitDataFrozen || app.onboardingSaving)
        .task {
            if !app.ready { await app.load() }
            if app.ready && (model == nil || model?.isClosed == true) { createModel() }
        }
        .onOpenURL { url in
            guard !app.finalQuitDataFrozen, AddressResolver.isWebURL(url) else { return }
            if let model, !model.isClosed { model.newTab(url: url) }
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
struct BrowserTabContent<Placeholder: View>: View {
    @ObservedObject var tab: BrowserEngineTab
    var hasPage: Bool
    var onUseWebKit: () -> Void
    @ViewBuilder var placeholder: () -> Placeholder
    var body: some View {
        if hasPage || (tab.chromiumSessionPages?.count ?? 0) > 1 || tab.errorMessage != nil { BrowserPage(tab: tab, onUseWebKit: onUseWebKit) }
        else { placeholder() }
    }
}
struct BrowserPage: View {
    @ObservedObject var tab: BrowserEngineTab
    var onUseWebKit: (() -> Void)?
    private var showPage: Bool { tab.errorMessage == nil || tab is ChromiumTab }
    var body: some View {
        VStack(spacing: 0) {
            if tab.loading { ProgressView(value: tab.progress).progressViewStyle(.linear).frame(height: 2) }
            if let error = tab.errorMessage {
                if tab is ChromiumTab {
                    HStack(spacing: 12) {
                        Text(error).font(.callout).lineLimit(3).help(error).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Reload page") { tab.reload() }.buttonStyle(.bordered)
                        if let onUseWebKit { Button("Reopen in WebKit") { onUseWebKit() }.buttonStyle(.bordered) }
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                } else {
                    VStack(spacing: 16) {
                        EmptyPanel(title: "This page needs attention", icon: "exclamationmark.circle", detail: error)
                        Button("Reload page") { tab.reload() }.buttonStyle(.borderedProminent).padding(.bottom, 32)
                        if tab.engineID == .chromium, let onUseWebKit { Button("Reopen in WebKit") { onUseWebKit() }.padding(.bottom, 24) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Mounting Chrome changes its navigation capability. Keep the
            // representable's identity stable across that callback and errors.
            WebViewHost(tab: tab)
                .frame(maxWidth: .infinity, maxHeight: showPage ? .infinity : 0)
                .opacity(showPage ? 1 : 0).allowsHitTesting(showPage).accessibilityHidden(!showPage).clipped()
        }
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

struct ZoomControls: View {
    @ObservedObject var tab: BrowserEngineTab
    var body: some View {
        HStack(spacing: 8) {
            Button("−") { tab.setZoom(tab.zoom - 0.1) }.buttonStyle(.plain).accessibilityLabel("Zoom out")
            Button("\(Int((tab.zoom * 100).rounded()))%") { tab.setZoom(1) }.buttonStyle(.plain).help("Reset zoom")
            Button("+") { tab.setZoom(tab.zoom + 0.1) }.buttonStyle(.plain).accessibilityLabel("Zoom in")
        }
    }
}

/// Neutrino saves management edits immediately. Its application delegate owns
/// download confirmation, final saving, and engine shutdown, even with a sheet open.
private struct BrowserSheetTerminationPolicy: NSViewRepresentable {
    func makeNSView(context: Context) -> PolicyView { PolicyView() }
    func updateNSView(_ view: PolicyView, context: Context) {
        view.window?.preventsApplicationTerminationWhenModal = false
    }
    @MainActor final class PolicyView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.preventsApplicationTerminationWhenModal = false
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Native window notifications provide the actual content width even when
/// SwiftUI preference propagation is interrupted by presentation modifiers.
struct BrowserLayoutRegion: NSViewRepresentable {
    let identifier: String
    var onWindowWidth: (@MainActor (CGFloat) -> Void)? = nil
    func makeNSView(context: Context) -> RegionView {
        let view = RegionView(); view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.onWindowWidth = onWindowWidth; return view
    }
    func updateNSView(_ view: RegionView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(identifier); view.onWindowWidth = onWindowWidth
    }
    @MainActor final class RegionView: NSView {
        var onWindowWidth: (@MainActor (CGFloat) -> Void)?
        private var resizeObservation: NotificationObservation?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); resizeObservation = nil
            guard let window, onWindowWidth != nil else { return }
            resizeObservation = NotificationObservation(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishWindowWidth() }
            })
            // Attaching an AppKit view can happen during a SwiftUI update.
            Task { @MainActor [weak self] in self?.publishWindowWidth() }
        }
        private func publishWindowWidth() {
            guard let width = window?.contentView?.bounds.width, width.isFinite, width > 0 else { return }
            onWindowWidth?(width)
        }
    }
}
