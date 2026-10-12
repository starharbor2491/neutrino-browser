// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// macOS view lifecycle only; the guided flow and controls are rendered by Rust.
struct OnboardingView: View {
    @EnvironmentObject private var app: AppState
    var previewStep: Int? = nil
    var body: some View { RustShellView(app: app, model: nil, previewStep: previewStep) }
}
