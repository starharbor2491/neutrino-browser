# Neutrino verification

Run `./scripts/test.sh` with Rust 1.88+, Swift 6 and SQLite development headers. macOS additionally builds and tests the native app targets. Linux runs the Rust workspace and portable Swift core/reader tests.

## Verified in this workspace

On Linux with Swift 6.2.1:
- 71 Swift Testing cases and 12 portable XCTest cases passed.
- Six installed-acceptance, six core-publication, and four disk-image retry Python regressions passed.
- All 18 bundled module packages validated.

The portable suite covers database round trips/recovery, modules and transactional rollback, distribution trust policy, reader bounds, Profiles/Spaces, live-tab ownership, archiving, blocker host boundaries, AI endpoint restrictions, and foreign/duplicate organization proposals.

Swift syntax parsing checks grammar, not macOS type checking or execution. Native verification runs separately on GitHub's Apple Silicon macOS runners.

## Rust rebuild checks

`8863146` passes 21 Rust workflow/core tests and 71 portable Swift tests, including existing bookmark import/export and SQLite persistence/recovery cases after their Rust migration. Browser-harness checks independently cover search destinations, narrow Library, folders, editor save/discard, docking, note scroll, live identity/error updates, and text Undo/Redo. Follow-up checks cover slider-focused Undo, live account-option availability, and replacement of editable nodes on Profile changes.

The native `RustShellNativeTests` suite uses an actual WKWebView to exercise a large library, immediate note dismissal, live security/error updates during note editing, native text Undo, auxiliary Downloads isolation, canonical AI endpoints and view ownership. Installed smoke also checks editor draft isolation and live-document identity/geometry. These checks must pass on the final compiled revision.

`0ccc58d` [macOS CI](https://github.com/starharbor2491/neutrino-browser/actions/runs/38230973377) built and installed the Rust shell, but its black setup captures are invalid visual evidence. Subsequent native compilation failures were fixed, not reported as passes. [c4aa34b native CI](https://github.com/starharbor2491/neutrino-browser/actions/runs/38237647239) passed portable, debug/release native, package and installed-shell checks. Its seven setup images are distinct WKWebView snapshots. The new live-page editor is being verified on its own subsequent revision.

## Historical release CI evidence

Pre-Rust released executable source: `92582400110bec4b6025c33532464ea53298ab40`.

[macOS and portable CI](https://github.com/starharbor2491/neutrino-browser/actions/runs/38138834489) passed. The debug suite runs 161 tests; release native integration runs 90. The development WebKit app ZIP/DMG passed sealed copy, detached installed launch, ordinary quit and removal. Native captures cover the shell, settings, editor and all eight setup screens. Visual review previously caught and corrected an overflowing editor inspector; its header, exit and Save controls remain visible. Screenshot capture does not verify interactive setup completion or all editor/accessibility workflows.

[Preview publication](https://github.com/starharbor2491/neutrino-browser/actions/runs/38138835891) passed native build/tests and the real updater helper tests with the complete Blink bundle. A fresh macOS runner expanded the actual ZIP, compared its sealed code against the DMG, and verified installed shell launch, saved SQLite data, normal application-delegate quit, helper exit, and removal without changing the external library. GitHub's uploaded ZIP/DMG digests match their verified package receipt. The release includes `installed-smoke.json` and the independent failed `blink-acceptance.json`/log.

The real helper test uses the packager's independent Apple `codesign` CDHash, rejects missing/wrong hashes, waits for a live parent to exit, replaces the app, checks version/security-floor changes, and verifies that external library, Profile, module and preference files remain byte-identical. Normal quit does not relaunch the replacement. Preview trust is the pinned GitHub repository plus download/code-seal checks; consumer trust additionally requires the same Developer ID publisher and notarization.

[Blink integration CI](https://github.com/starharbor2491/neutrino-browser/actions/runs/38129249568) builds the complete Apple Silicon app and DMG. Rendering, custom tab/address commands, retained documents, popup POST/opener behavior, Profile/private isolation, Reader/capture and genuine Web Store installation pass. The full MV3 fixture fails with **Browser window has no toolbar** when exercising `chrome.action.openPopup`. Full Blink installed shutdown/restart acceptance therefore remains unverified. This failure remains a core release gate; the checks have not been disabled or treated as passing.

## Native and installed gates

On an Apple Silicon Mac:

```sh
./scripts/test.sh
./scripts/build-app.sh
python3 scripts/package-release.py --development
python3 scripts/installed-smoke.py --chromium-restart
```

The Rust packaged smoke runner advances through seven guided setup screens using the real command bridge. It captures them with WKWebView snapshots and rejects identical images. It does not use a real account. Current screenshot and interaction results must be reviewed separately from the historical eight-screen implementation.

Native workspace tests use a real WebKit document to check live-tab identity, unsaved form/JavaScript preservation, callback rewiring, shared descriptors, per-Space setups, and inactive Profile cleanup. Existing services retain real store/worker/download/write-failure tests.

Blink acceptance must check Neutrino-owned Command-T/W/L behavior, child geometry/focus, retained documents, navigation/retry, popup POST/opener behavior, private/Profile separation, Reader/capture, download terminal ownership, and ordinary shutdown. Full MV3 and genuine Web Store installation/restart checks remain mandatory. Old inner-tab/group checks describe extension API compatibility, not the default browser UI.

The installed driver verifies receipt bytes, sealed code, read-only mounting, payload closure, copy/detach/launch, actual application-delegate termination acceptance, helper exit, safe app removal, and preserved external user data. Watchdog TERM/forced cleanup fails acceptance even with exit code zero.

## Manual core acceptance

- Complete setup before browsing; optional import/AI can remain unused; persist setup failures visibly.
- Review default shell, start, settings, editor, and setup on actual macOS in multiple sizes/light/dark. Test VoiceOver, keyboard navigation, contrast, reduced motion/transparency, and recovery.
- Share a Space across two windows. Transfer a form/media tab without reload. Switch Spaces and Profiles, duplicate, pin/file/reorder, archive/restore, split, close/reopen, quit/relaunch.
- Verify safe address/search/history/bookmarks, find/zoom, errors/retry, downloads/cancel/replace, private isolation, permission origins, and Profile cleanup.
- Verify complete local password/save/update/autofill and ad/tracker filtering workflows before marking those core rows complete; current manual filling/starter rules are partial.
- Install/update/disable/remove extensions; verify actions, panels, settings, permissions, workers, and tab/window APIs in the custom host.
- Verify licensed CDM/codecs and representative protected streaming, including playback after install/restart.
- Test BYOK and local endpoints, explicit page/tab sharing, rejected organization proposals, stale proposal rejection, and reviewed application. Test OpenAI account sign-in/refresh/model discovery/inference/revocation; xAI requires its own supported registration.
- Verify a complete offline signed/notarized DMG on a clean Mac with normal Gatekeeper behavior, engine/helper payloads, first-run setup, trusted update/restart, and rollback.

Record tested source/binary and actual outcomes. A skipped gate, parser pass, or historical receipt cannot certify the core release. See [PARITY.md](PARITY.md).
