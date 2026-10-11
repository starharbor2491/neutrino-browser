# Neutrino rebuild status

Neutrino is being rebuilt against [the confirmed brief](PRODUCT_PLAN.md). No Neutrino core release or complete parity claim has been verified.

Implemented source includes a custom workspace shell/start surface, an eight-stage first-run flow, a docking editor, named per-Space setups, shared tab state and live-tab transfer ownership, folders, optional recoverable archiving, local Keychain password storage/requested login filling, starter blocking rules, BYOK/local page and selected-text assistance, validated organization proposals, and the documented OpenAI OSS account flow.

Blink now uses Chrome-style CEF Views without Chrome's navigation toolbar. ABI 5 and runtime style `chromeViews` deliberately reject old hosting packages. Native checks verify rendering, Neutrino tab/address commands, retained documents, popup POST/opener behavior, Profile/private isolation, Reader/capture and genuine Web Store installation. Full extension acceptance fails because `chrome.action.openPopup` requires a browser toolbar; a Neutrino-owned replacement still needs engine integration. The complete Blink installer is not accepted for release.

Build/package scripts target Apple Silicon and include Blink by default. Explicit WebKit-only development builds are incomplete. Consumer signing/notarization still require configured credentials.

## Verification boundary

Portable Swift tests cover storage, module integrity/transactions, privacy records, workspace normalization, ownership, archiving, endpoint validation, and organization boundaries. macOS CI passes 160 tests in debug and 89 native tests in release, builds the app, captures its interface and verifies installed WebKit launch, ordinary quit and removal. Python tests cover installed-acceptance handling; all 18 module packages validate. Exact source and CI evidence are recorded in [TESTING.md](TESTING.md).

Outstanding gates:
- Interactive setup/editor acceptance, accessibility and clean-Mac verification.
- Full Blink extension/API compatibility, action popup integration and installed shutdown/restart acceptance.
- Widevine/CDM licensing, codec distribution, and protected streaming playback.
- Native OpenAI sign-in/refresh/revocation/model discovery/inference; xAI registration/entitlements.
- Developer ID/notarization and the complete new installer.

See [TESTING.md](TESTING.md) and [PARITY.md](PARITY.md). [AUDIT.md](AUDIT.md) and [1.0.0 notes](RELEASE_NOTES_1.0.0.md) are historical predecessor records; they do not validate Neutrino.

The publishing workflow requires exact-installer installed acceptance and publisher-recorded core checks, including protected streaming. No passing Neutrino core receipt is supplied.
