# Neutrino rebuild status

Neutrino is being rebuilt against [the confirmed brief](PRODUCT_PLAN.md). No Neutrino core release or complete parity claim has been verified.

[Neutrino 1.0.1-preview.1](https://github.com/starharbor2491/neutrino-browser/releases/tag/v1.0.1-preview.1) is available for Apple Silicon as a compiled app ZIP and an offline DMG containing Blink, WebKit support, built-in modules, and the updater. Its exact ZIP/DMG passed installed shell launch, normal quit, and external-data preservation. Published previews automatically check GitHub, download compatible newer releases, and replace only the app after quitting. This is an ad-hoc signed development preview; consumer/core acceptance remains incomplete.

The active Rust rebuild replaces the previous SwiftUI screen collection with custom browser chrome, seven-step setup, command search, a docking editor, and draggable tab/folder/Space organization. SQLite transactions, bookmark exchange, address resolution, blocking rules, reader-feed parsing and AI validation now run in Rust. Native engine ownership, Keychain, modules/workers, downloads, networking and distribution adapters remain. See [Rust architecture](RUST_ARCHITECTURE.md) and the [gauntlet record](GAUNTLET.md).

The retained services include shared tabs, per-Space configurations, recoverable archiving, local passwords/manual filling, starter blocking, BYOK/local page assistance and OpenAI account plumbing. Detailed style/component editing, named-setup management, module-specific settings and the organization proposal review/apply interface still need full integration in the Rust frontend; a retained model or service does not count as a complete workflow.

Blink now uses Chrome-style CEF Views without Chrome's navigation toolbar. ABI 6 and runtime style `chromeViews` deliberately reject old hosting packages. Prior native checks verify rendering, Neutrino tab/address commands, retained documents, popup POST/opener behavior, Profile/private isolation, Reader/capture and genuine Web Store installation. Full extension acceptance fails because `chrome.action.openPopup` requires a browser toolbar; a Neutrino-owned replacement still needs engine integration. That failed result is attached to the preview and still blocks consumer/core release acceptance.

Build/package scripts target Apple Silicon and include Blink by default. Explicit WebKit-only development builds are incomplete. Consumer signing/notarization still require configured credentials.

## Verification boundary

Portable Swift tests cover storage, module integrity/transactions, privacy records, workspace normalization, ownership, archiving, endpoint validation, and organization boundaries. The released pre-Rust source passed 161 tests in debug and 90 native tests in release; current-revision results are recorded in TESTING.md. Native tests launch the real updater, compare its code hash with release packaging, wait for parent exit, replace a sealed app and retain external Profile files. Installed acceptance expands the actual app ZIP, verifies it against the DMG, and checks launch, ordinary quit and preserved external user data. Sixteen Python regressions pass; all 18 module packages validate. Exact source and CI evidence are recorded in [TESTING.md](TESTING.md).

Outstanding gates:
- Interactive setup/editor acceptance, accessibility and clean-Mac verification.
- Full Blink extension/API compatibility, action popup integration and installed shutdown/restart acceptance.
- Widevine/CDM licensing, codec distribution, and protected streaming playback.
- Native OpenAI sign-in/refresh/revocation/model discovery/inference; xAI registration/entitlements.
- Developer ID/notarization and clean-Mac consumer installer acceptance.

See [TESTING.md](TESTING.md) and [PARITY.md](PARITY.md). [AUDIT.md](AUDIT.md) and [1.0.0 notes](RELEASE_NOTES_1.0.0.md) are historical predecessor records; they do not validate Neutrino.

Consumer publishing requires exact-installer installed acceptance and publisher-recorded core checks, including protected streaming. Preview publishing requires native/updater and independent installed-shell acceptance, and attaches the full Blink result without treating a failure as core acceptance. No passing Neutrino core receipt is supplied.
