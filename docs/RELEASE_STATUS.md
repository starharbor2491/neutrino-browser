# Neutrino Studio release status

[Compiled Apple Silicon previews](https://github.com/starharbor2491/neutrino-browser/releases) contain `Neutrino.app` in a ZIP and a complete offline DMG. Blink, WebKit support, built-in modules, and the updater ship inside the app. Browser data stays outside the replaceable application bundle.

Studio implements command-first destinations without a new-tab page, six familiar onboarding layouts, direct tab/folder/Space manipulation, source-linked project notes beside live pages, split comparisons, SVG icon packs, and a docking/appearance editor with reusable setups. Modules contribute workspace controls, menus, widgets, styling, or removable feature workers. Named setup saves wait for native confirmation; rejected saves retain the draft.

## Verification

Source `42afdff` passed [complete installed Blink acceptance](https://github.com/starharbor2491/neutrino-browser/actions/runs/38646385546) and [macOS/portable CI](https://github.com/starharbor2491/neutrino-browser/actions/runs/38646385368). GitHub tested merge checkout `be72c14`, whose tree `6ae899b` exactly matches that head. Native results include 169 debug tests, 97 release tests, sealed DMG/ZIP comparison, ordinary shutdown, a full process restart with extension persistence/removal, and unchanged external user data.

Both engines pass actual note-input editing and SQLite body reload, distinct quotations, content search, original source identity and cross-Space recovery, retained splits, presets, named setups, and bounded large-note projection. Blink additionally passes original inner-page identity/cold restoration, MV3 action popups/side panels/options/update/removal, Chrome Web Store installation, private/Profile isolation, popup/opener/POST behavior, and strict native viewport geometry. Native windows close before CEF teardown; both processes exit through ordinary application termination.

The final renderer also removes duplicate module-provided menu destinations. Its 46 Rust workflows and rendered disabled/enabled/repeated-entry checks pass. This later change is not covered by the earlier installed receipt: publication requires fresh complete native acceptance of the final packaged app. Each release attaches those exact-binary receipts.

The portable suite additionally covers three executable worker protocols, 72 Swift adapter/core tests, all 18 bundled packages, and packaging/update regressions. The README uses actual native WebKit captures of local sample articles, the live editor, and guided setup. These images establish presentation; source and installed receipts establish behavior. See [testing](TESTING.md) for evidence boundaries and [the gauntlet record](GAUNTLET.md) for failures and independent reviews.

Each preview is rebuilt, installed, and verified on a fresh macOS runner before publication. Its attached receipts certify that exact packaged app. Screenshots, parser tests, historical receipts, and diagnostic exits cannot substitute for that verification.

The first final release candidate (`33e7474`, run [38648337999](https://github.com/starharbor2491/neutrino-browser/actions/runs/38648337999)) passed native tests, all five real updater replacement/rollback/data-preservation tests, installed WebKit, and both research receipts. A later Web Store registry query timed out in an unmounted test-only browser, so publication was refused. The verifier now uses its own real window after native approval, preserving the initiating Store page and all registry, deadline, quit, and restart gates. A fresh packaged-binary run is required for this correction.

## Remaining consumer-release gates

- Developer ID signing/notarization and clean-Mac Gatekeeper acceptance. Without configured Apple credentials, previews are ad-hoc signed and may require Open Anyway.
- A configured Sparkle publisher key and signed feed. The verified GitHub updater remains active until a keyed build is published; previously compiled binaries receive it through that bridge.
- Licensed CDM/codecs and representative protected streaming playback.
- Complete password/autofill and filter-list coverage; broader extension compatibility and advanced parity beyond the retained fixtures.
- VoiceOver/manual accessibility, OpenAI account inference/refresh/revocation, and supported xAI account registration/entitlements.

The concrete customer hypothesis is local research: quotations retain provenance, notes stay beside live sources, moved sources return without losing their document, and saved setups preserve comparison context. Native acceptance validates that workflow; it does not establish universal replacement of Arc, Brave, or Chrome. No finished-core or 100% parity claim is made.

[Confirmed brief](PRODUCT_PLAN.md) · [Feature coverage](PARITY.md) · [Distribution](DISTRIBUTION.md) · [Gauntlet](GAUNTLET.md)

The host uses an upstream normal Chromium window clipped above Neutrino's viewport. ABI 8 and `hostPresentation=clippedNative` identify this integration. The `chromeViews` manifest family label remains compatible with existing whole-application update validators; it does not allow predecessor engine packages to load in Studio.
