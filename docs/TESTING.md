# Neutrino verification

Run `./scripts/test.sh` with Rust 1.88+, Swift 6 and SQLite development headers. macOS additionally builds and tests the native app targets. Linux runs the Rust workspace and portable Swift core/reader tests.

## Current verification

The current Linux suite passes 46 Rust workflow tests, three executable worker-protocol tests, 72 Swift Testing cases, 12 XCTest cases, all 18 bundled packages, and the packaging/update regression suites. These cover database recovery and revision ordering, cancelled autosaves, module transactions, worker bounds and process exit, imports, Profiles/Spaces, live-tab ownership, distribution trust and AI endpoint restrictions.

Source `42afdff` passes [complete installed Blink acceptance](https://github.com/starharbor2491/neutrino-browser/actions/runs/38646385546) and [macOS/portable CI](https://github.com/starharbor2491/neutrino-browser/actions/runs/38646385368), including 169 native debug tests, 97 release tests, both research workflows, full MV3/Web Store coverage, ordinary quit, extension persistence/removal after a second process launch, and preserved external data. GitHub's tested merge checkout `be72c14` has the exact head tree `6ae899b`. The final menu deduplication passes all 46 Rust workflows and direct rendered checks with the module disabled/enabled/repeated; a fresh final packaged-binary native run remains mandatory before publication. Historical failures and source-specific independent findings remain in [GAUNTLET.md](GAUNTLET.md).

The research receipt exercises quote provenance, different same-source excerpts, phrase matching beyond the list excerpt, note-content matching, original live-tab identity, moved-source recovery with the note still visible, durable database reload, split retention, and named setups. Unselected note bodies remain outside passive interface snapshots. The cancellation test proves that a discarded revision 99 cannot suppress a valid revision 2 or poison a reopened database.

Fixture interactions independently cover command cancellation, tab/folder/Space dragging, gestures and Undo, six presets, four SVG packs, component docking/resizing, narrow editor containment, keyboard selection, named setup acknowledgement, module controls, source search/recovery, and reduced motion. These are interface checks, not native-engine compatibility evidence. Native screenshots use the OS compositor to include Blink child windows.

The installed research check uses local sample articles with distinct titles and quotations, plus live forms and file inputs. It edits a source-linked note through the actual textarea input handler and checks its body after SQLite reload. Screenshot presentation uses a wider dark vertical layout, then restores the previous frame and configuration. These sample articles are test content, not third-party pages or a claim of website compatibility.

Swift syntax parsing checks grammar; it cannot establish macOS compilation or execution. Apple Silicon CI separately runs real WKWebView/CEF ownership, worker sampling/reaping, private/Profile isolation, downloads and native distribution tests. The updater helper replaces a sealed application while verifying byte-identical external library, Profile, module and preference data; rejection and rollback are also tested.

Earlier source-specific failures and responses remain recorded in the [Gauntlet log](GAUNTLET.md). Each release publishes its own installed receipts; historical receipts do not certify a later executable.

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
