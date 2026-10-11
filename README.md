# Neutrino

A customizable, local-first macOS browser for Apple Silicon: Arc-inspired workspaces, a quiet custom interface, a visual docking editor, and Blink/WebKit adapters.

This repository is being rebuilt against a [confirmed product brief](docs/PRODUCT_PLAN.md). The new product is not yet a verified core release. See [status](docs/RELEASE_STATUS.md) and the [parity ledger](docs/PARITY.md).

- Spaces organize shared tabs/folders; Profiles isolate website accounts.
- Live tabs transfer between windows without intentionally reloading their documents.
- Guided setup, custom shell, docking preview/undo, and named per-Space appearances.
- Keychain passwords, requested login filling, starter blocking rules, and recoverable tab archiving.
- Optional BYOK/local AI, explicit page/selected-text sharing, and reviewed organization proposals. OpenAI OSS OAuth is implemented in source but awaits native acceptance; xAI registration is pending.
- Existing SQLite, modules/workers, privacy cleanup, downloads, reader/capture, recovery, and trusted updater infrastructure remain reusable.

The finished target covers locally runnable Arc/Chrome/Opera/GX workflows in verified stages. No hosted sync, VPN, cloud storage, or Neutrino store.

## Build on Apple Silicon

Requires macOS 14+, Swift 6/Xcode, Python 3, and CMake. Fetching the pinned CEF SDK requires network access during the build; the complete installer is intended to work offline.

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

[Testing](docs/TESTING.md) · [Engines](docs/CHROMIUM.md) · [Distribution](docs/DISTRIBUTION.md) · [Design](docs/DESIGN.md) · [AI](docs/AI.md) · [Licensing](docs/LICENSING.md)

New code is MPL-2.0; the original repository retains its MIT license. Historical release records remain truthful.
