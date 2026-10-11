# Neutrino verification

Run `./scripts/test.sh` with Swift 6 and SQLite development headers. macOS additionally builds and tests the native app targets. Linux runs portable core/reader tests only.

## Verified in this workspace

On Linux with Swift 6.2.1:
- 70 portable Swift tests passed.
- Six installed-acceptance and six core-publication Python regressions passed.
- All 18 bundled module packages validated.

The portable suite covers database round trips/recovery, modules and transactional rollback, distribution trust policy, reader bounds, Profiles/Spaces, live-tab ownership, archiving, blocker host boundaries, AI endpoint restrictions, and foreign/duplicate organization proposals.

Swift syntax parsing checks grammar, not macOS type checking or execution. No macOS native tests or screenshots have run for the rebuilt Neutrino in this environment. Update this record if the source changes or more checks run.

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
