# Neutrino verification

Run `./scripts/test.sh` with Swift 6 and SQLite development headers. macOS additionally builds and tests the native app targets. Linux runs portable core/reader tests only.

## Verified in this workspace

On Linux with Swift 6.2.1:
- 71 portable Swift tests passed.
- Six installed-acceptance and six core-publication Python regressions passed.
- All 18 bundled module packages validated.

The portable suite covers database round trips/recovery, modules and transactional rollback, distribution trust policy, reader bounds, Profiles/Spaces, live-tab ownership, archiving, blocker host boundaries, AI endpoint restrictions, and foreign/duplicate organization proposals.

Swift syntax parsing checks grammar, not macOS type checking or execution. Native verification runs separately on GitHub's Apple Silicon macOS runners.

## Native CI evidence

Executable source: `79509ce1b8a70861332d3f65426a027d7335b4be`.

[macOS and portable CI](https://github.com/starharbor2491/neutrino-browser/actions/runs/38129249593) passed. The debug suite runs 160 tests; release native integration runs 89. The development WebKit DMG passed sealed copy, detached installed launch, ordinary quit and removal. Native captures cover the shell, settings, editor and all eight setup screens. Visual review caught and corrected an overflowing editor inspector; its header, exit and Save controls now remain visible. Screenshot capture does not verify interactive setup completion or all editor/accessibility workflows.

[Blink integration CI](https://github.com/starharbor2491/neutrino-browser/actions/runs/38129249568) builds the complete Apple Silicon app and DMG. Rendering, custom tab/address commands, retained documents, popup POST/opener behavior, Profile/private isolation, Reader/capture and genuine Web Store installation pass. The full MV3 fixture fails with **Browser window has no toolbar** when exercising `chrome.action.openPopup`. Full Blink installed shutdown/restart acceptance therefore remains unverified. This failure remains a core release gate; the checks have not been disabled or treated as passing.

## Native and installed gates

On an Apple Silicon Mac:

```sh
./scripts/test.sh
./scripts/build-app.sh
python3 scripts/package-release.py --development
python3 scripts/installed-smoke.py --chromium-restart
```

The packaged smoke runner also captures all eight guided setup screens without completing the wizard or accessing a real account; those captures still require macOS execution and visual review.

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
