# Neutrino

A customizable, local-first macOS browser for Apple Silicon: Arc-inspired workspaces, a quiet custom interface, a visual docking editor, and Blink/WebKit adapters.

This repository is being rebuilt against a [confirmed product brief](docs/PRODUCT_PLAN.md). The new product is not yet a verified core release. See [status](docs/RELEASE_STATUS.md) and the [parity ledger](docs/PARITY.md).

Download compiled Apple Silicon builds from [GitHub Releases](https://github.com/starharbor2491/neutrino-browser/releases). Each Neutrino release includes a ZIP containing `Neutrino.app`, an offline DMG, and checksums. Published builds check GitHub for updates, download compatible newer versions, and install after a normal quit while retaining browsing data. Preview releases remain development builds with the limitations recorded in their release notes.

Native captures of the Rust interface from [Apple Silicon CI](https://github.com/starharbor2491/neutrino-browser/actions/runs/38274338963) (`2d97d23`, PR merge checkout `04bd0e65`). These show the compiled app; interaction and release gates are recorded separately in [Testing](docs/TESTING.md):

![Neutrino's custom workspace shell](docs/images/neutrino-shell.png)

<details>
<summary>View the docking editor</summary>

![Neutrino's docking editor with visible exit and Save controls](docs/images/neutrino-editor.png)

![Neutrino’s guided setup](docs/images/neutrino-setup.png)

</details>

- Spaces organize shared tabs/folders; Profiles isolate website accounts.
- Live tabs transfer between windows without intentionally reloading their documents.
- Rust-rendered guided setup and shell, draggable tabs/folders/Spaces, docking previews, Undo/Redo, and per-Space appearances.
- Keychain passwords, requested login filling, starter blocking rules, and recoverable tab archiving.
- Optional BYOK/local AI and explicit page/selected-text sharing. Organization proposal validation is retained; its review/apply interface remains work. OpenAI OSS OAuth is implemented in source but awaits native acceptance; xAI registration is pending.
- Rust SQLite persistence and bookmark exchange; retained modules/workers, privacy cleanup, downloads, reader/capture, recovery, and trusted updates.

The finished target covers locally runnable Arc/Chrome/Opera/GX workflows in verified stages. No hosted sync, VPN, cloud storage, or Neutrino store.

## Build on Apple Silicon

Requires macOS 14+, Rust 1.88+, Swift 6/Xcode, Python 3, and CMake. Fetching the pinned CEF SDK requires network access during the build; the complete installer is intended to work offline.

```sh
./scripts/test.sh
./scripts/build-app.sh
python3 scripts/package-release.py --development
```

The default build includes Blink, WebKit, engine helpers, bundled modules, and the updater. Development artifacts are ad-hoc signed. Consumer packaging requires Developer ID/notarization credentials and all core acceptance gates.

An explicitly incomplete shell-development build is available with:
```sh
NEUTRINO_WEBKIT_DEVELOPMENT_ONLY=1 ./scripts/build-app.sh
```

The custom Blink host needs native/extension acceptance. Blink alone does not establish licensed DRM playback or every extension API.

[Rust architecture](docs/RUST_ARCHITECTURE.md) · [Gauntlet](docs/GAUNTLET.md) · [Testing](docs/TESTING.md) · [Engines](docs/CHROMIUM.md) · [Distribution](docs/DISTRIBUTION.md) · [Design](docs/DESIGN.md) · [AI](docs/AI.md) · [Licensing](docs/LICENSING.md)

New code is MPL-2.0; the original repository retains its MIT license. Historical release records remain truthful.
