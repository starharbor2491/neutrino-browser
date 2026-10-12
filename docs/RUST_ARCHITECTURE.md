# Rust interface and core boundary

The browser interface is rendered by `crates/neutrino-shell`. Rust owns the HTML, control state, command search, seven-step setup, tab move validation/undo, editor drafts, docking, appearance choices, and navigation between screens. The bundled CSS supplies the visual system; a small JavaScript adapter handles DOM events, drag/drop, focus, editable-node reconciliation, and geometry reporting. No remote web content is used to render the interface.

A private, nonpersistent WKWebView displays these bundled assets through `neutrino-ui://shell`. Its message handler accepts only its own main frame. Website engine views are separate native children placed in the rectangles reported by the shell. Opening a modal hides those website views, and generation checks reject stale geometry. A crashed shell reloads the bundled document without discarding the Rust interaction state.

The C ABI exchanges bounded JSON and opaque handles. Rust owns and frees its returned strings. The native host validates IDs against the current Profile/Space and only permits declared commands. Password values remain in Keychain and never enter the browser snapshot. Auxiliary download windows receive only their download capability.

Rust also owns address/search resolution, AI endpoint validation/canonicalization, organization proposal validation, reader-feed parsing, blocking rules, bookmark HTML import/export, SQLite transactions/revision ordering/checkpoints, and SVG icon rasterization. The database schema and external data directory remain compatible with the updater. Bookmark export failures propagate rather than producing empty files.

Swift remains in the AppKit/WebKit/CEF view adapters, application lifecycle, Keychain, native file/default-browser/permission dialogs, downloads, account networking, and signed distribution services. Existing Swift Codable models and module/worker infrastructure are retained, so this is not a claim that all portable Swift has been eliminated. The rendering and interaction code no longer relies on the previous SwiftUI screen collection. CEF integration remains Objective-C++ against upstream CEF, with ABI 6 custom browser chrome and ordinary-tab close requests.

## Build

Rust 1.88 or newer, Swift 6/Xcode, Python 3, SQLite headers, and CMake are required. `scripts/build-rust.sh` builds the static library before SwiftPM links it. `scripts/test.sh` runs the Rust and Swift suites plus packaging/acceptance regressions. `Cargo.lock` pins dependencies. macOS packaging compiles the supplied `neutrino.svg` to an icon set without changing its artwork.

`cargo run -p neutrino-shell --bin preview` provides a loopback fixture harness at `127.0.0.1:4317`; `/setup` opens first run. It is not bundled and does not contain a website engine, Keychain, or live Profiles. It verifies renderer interactions only. Native tests and installed-app acceptance are separate gates.
