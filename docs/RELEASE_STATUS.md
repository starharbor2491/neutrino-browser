# Neutrino Studio release status

[Compiled Apple Silicon previews](https://github.com/starharbor2491/neutrino-browser/releases) contain `Neutrino.app` in a ZIP and a complete offline DMG. Blink, WebKit support, bundled modules, and the updater ship inside the app. Browser data stays outside the replaceable application bundle.

Studio implements command-first destinations without a new-tab page, six familiar onboarding layouts, direct tab/folder/Space manipulation, source-linked project notes beside live pages, split comparisons, SVG icon packs, and a docking/appearance editor with reusable setups. Modules contribute workspace controls, menus, widgets, styling, or removable feature workers. Named setup saves wait for native confirmation; rejected saves retain the draft.

## Evidence

Source `9df79ea` passed native WebKit CI and the research workflow in both engines: selected quotations, source identity across Space moves, separate same-URL tabs, durable SQLite notes, live split retention, presets, named setups, and large-note UI projection. Its complete Blink gate failed at extension action popups. The subsequent host uses a normal upstream Chromium window with native chrome clipped above the Neutrino viewport, tagged ABI 8 / `chromeClipped`. This change requires fresh installed geometry, extension-popup and shutdown verification before publication.

The current portable checks pass 41 Rust workflows, 71 Swift adapter/core tests, package validation, and packaging/update regressions. The [testing record](TESTING.md) separates fixture interactions, native tests, installed artifacts, and historical results. Screenshots and parser tests do not certify browser compatibility.

Preview publication now requires installed launch, ordinary quit, external-data preservation, research acceptance in both engines, and complete Blink/MV3 acceptance against the exact packaged app. Consumer publishing additionally requires the manual core, protected streaming, signing, and clean-Mac gates.

## Remaining release gates

- Developer ID signing/notarization and clean-Mac Gatekeeper acceptance. Without configured Apple credentials, previews are ad-hoc signed and may require Open Anyway.
- A configured Sparkle publisher key and signed feed. The verified GitHub updater remains active until a keyed build is published; previously compiled binaries receive it through that bridge.
- Licensed CDM/codecs and representative protected streaming playback.
- Complete password/autofill and filter-list coverage; broader extension compatibility and advanced parity beyond the retained fixtures.
- VoiceOver/manual accessibility, OpenAI account inference/refresh/revocation, and supported xAI account registration/entitlements.

The concrete customer hypothesis is local research: quotes retain provenance, notes stay beside the live source, moved sources return without losing their document, and saved setups preserve the comparison context. Native acceptance validates that workflow; it is not evidence that Neutrino universally replaces Arc, Brave, or Chrome. No core-release or 100% parity claim is made.

[Confirmed brief](PRODUCT_PLAN.md) · [Feature coverage](PARITY.md) · [Distribution](DISTRIBUTION.md) · [Gauntlet](GAUNTLET.md)
