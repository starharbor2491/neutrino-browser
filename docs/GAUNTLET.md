# Interface rebuild gauntlet

One implementer owns code changes. Three independent, read-only critics review code, UI and UX; no implementation is delegated. The supplied `neutrino.svg` is unchanged, including its artwork. The app and installer use generated raster sizes from that source.

The reference is Arc for macOS: its published interface and documented tab/Space workflows. Compare actual renderings at comparable sizes, with identifying labels removed where practical. Source review does not count as visual review. Screenshots do not establish interaction behavior. No numerical taste scores or fixed round limit substitute for a critic’s preference.

Method adapted from [Gauntlet Loop](https://github.com/robonuggets/gauntlet-loop), by Jay E / RoboNuggets (CC BY 4.0), based on Matt Shumer’s builder/critic technique. [REA](https://github.com/morluto/rea) was used to discover and capture the running local Rust-rendered interface over CDP. That evidence concerns the fixture harness, not a macOS executable. Official Arc captures cover the sidebar, Spaces, pins, theme picker, and a published import flow; the historical import GIF is not represented as Arc’s entire current onboarding.

## Reference principles

- [Laws of UX](https://lawsofux.com/): familiar browser shortcuts, manageable choices, reachable targets, immediate feedback, spatial grouping.
- [Material](https://m3.material.io/components/buttons/overview): consistent action hierarchy and hover/focus/pressed/disabled states.
- [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop): direct manipulation, window behavior, keyboard/accessibility alternatives and recovery.
- [Carbon](https://carbondesignsystem.com/patterns/empty-states-pattern/): purposeful empty states, explicit labels, validation and recovery.

## Review record

| Source | Independent findings and resulting work | Evidence boundary |
| --- | --- | --- |
| `327af19` | Baseline SwiftUI composition, setup and interaction problems established. Replaced the screen collection with Rust rendering and a shared visual system. | Source and prior native captures. |
| `0ccc58d` | Docking, focus, editor exit/undo, narrow panels and engine/lifecycle defects identified. The native shell still had excess titlebar chrome; setup snapshots were black. | macOS CI passed, but black setup captures were explicitly rejected as visual evidence. |
| `cea661c` | Editor/folder grouping, note layout, menu focus and footer refinements. Code review found Profile leakage in auxiliary Downloads, global privacy propagation and AI lifetime issues. | Renderer checks; macOS failed on a missing redirect delegate, subsequently restored. |
| `4656345` | Auxiliary capabilities, privacy propagation, redirects, task identity, split error handling, favicon policy, SQLite migration and note storage reviewed. Critics found Settings search opening behind Settings, hidden narrow-sidebar action, note-list scroll reset, missing horizontal folder options, suppressed note updates, and two stale host projections. | Portable tests passed; native screenshot API did not compile, so no new native claim. |
| `8863146` | All four UX residuals passed. Live note typing retained node/caret and Chromium Undo/Redo while URL, error and privacy state updated. Code critic found no new P0/P1; account option availability remained stale. UX found slider-focused Undo suppressed. | Independent rendered-fixture and source review. Neither established native IME or Arc-wide parity. |
| `c4aa34b` | All seven setup images rendered. UI critic preferred Arc’s shell alignment and import hierarchy, and Neutrino’s displayed settings-control styling against the supplied cropped Arc settings reference. Extra titlebar/footer chrome resolved. Remaining findings: duplicate editor navigation, root scrollbar, ambiguous Profile/Space controls, Library category state, module identity/copy. | Native screenshots; first-launch/split cache captures were rejected. Subsequent captures use the OS window compositor. |
| `125d381` | Live page preview retained document identity but code criticism found incomplete input isolation for CEF child windows and page keyboard focus. UX found small-preview clipping, inaccessible scrolling and scope-focused Undo. | Source and fixture review; native build passed in CEF CI, while the full macOS job exposed a worker-reentry timing failure. |
| `246343f` | Per-coordinator input suspension reaches CEF focus/mouse handling and the WK responder boundary. Width gestures are continuous and coalesce to one Undo step. Preview content responds to its available area and supports inert scrolling. Library selection, profile glyph, import card alignment and module labels revised. Split geometry acceptance now compares the actual pane, rather than the first pane in the view tree. | Native keyboard positive/negative controls and parent-window mouse rejection added; real Chromium mouse targeting is additionally checked through its child-window input flag, not independently proved by those parent-directed events. Subsequent native runs verified keyboard positive/negative controls, frame geometry and document identity. |
| `5e0e85c` | Focused independent UX retests pass delayed input/passive updates with matching thumb/preview widths, consecutive gesture Undo/Redo, and nested Notes scrolling at both boundaries. No residual issue found in that focused fixture scope. | Served asset hash `8dabc5c7e7b642aa6f53ce106e785ebbd23b0108aea5f2ba8497f9354960d4d6`; native acceptance remains separate. |

The final visual critic reviewed valid OS-composited `5e0e85c` screenshots: resting shell alignment, narrow containment, dark appearance, Library selection, import alignment, Profile glyph and duplicate editor navigation were resolved. The critic still preferred Arc's shell/split grouping and import composition; the limited Settings comparison favored Neutrino's displayed controls. Remaining findings were dense split pages in the 1024 px editor, adjacent native scroll tracks, technical Reader copy, a toast covering the editor footer, repeated split titles, and excess space in Extensions. Follow-up work adds an expanded live preview, shorter module descriptions, a compact Extensions panel and a reserved feedback line in the editor footer, clear of native page windows. Native scroll geometry identified one shell scroll container per affected area; shell scrollbars now share explicit styling. These changes do not turn the critic's Arc preference into a claimed win.

`d19a1f0` native captures confirm the expanded preview and compact Extensions layout. The UI critic found that a floating editor toast was still covered by the native page; it now renders in the reserved recovery footer. `ba61efc` native acceptance verified Command-T/W/L and regular/private session-cookie lifetimes. Its menu probe incorrectly focused a detached page while the address palette was still open; the probe now dismisses the palette, waits for attachment/focus, and restores Rust chrome state during cleanup. The code critic verified this diagnosis without changing production menu ownership. The packaged app also tests Command-W with its palette open; this regression belongs in the app event loop, rather than manual event dispatch inside SwiftPM.

The focused final UI retest resolves the duplicate scrollbar finding in `ba61efc` native Modules/editor captures. Independent harness checks at 1024 × 684 and 1240 × 686 verify inline feedback stays inside the reserved footer, with zero preview overlap through expand/restore and no horizontal document overflow. The critic also confirmed the unobstructed feedback and visible Expand preview/Show controls in `7720c97` native WebKit captures. Its expanded page capture is blank and establishes layout only; document/geometry interaction checks are separate.

The current editor keeps the original native page mounted while its frame follows the layout draft, addressing the UX critic’s preference for Arc’s contextual customization. Input to the page is paused during editing, and dragging hides it briefly to expose docking targets. Cancel restores normal interaction on the same document. Native acceptance must prove this behavior; a fixture image cannot. Follow-up gesture code uses a local counter on the private WK origin, preserves the active preview width through late acknowledgements, and forwards remaining wheel movement from an exhausted note list into the Library panel.

## Required evidence

1. Shell, populated workspace, seven setup screens, editor, settings and command palette at wide/narrow sizes and light/dark appearances.
2. Pointer/keyboard reordering; pin/folder/Space moves; resize; docking feedback; cancellation; Undo/Redo.
3. Setup Back/Continue, validation, optional import/AI, interrupted-save retry and first successful navigation.
4. Native engine geometry/focus, split recovery, modal isolation, private/Profile boundaries, shared live documents, persistence and quit/relaunch.
5. Rust reducer/FFI and existing native service tests; escaped page titles, main-frame message isolation, no password values in UI snapshots.
6. Compiled-app identity, actual screenshots, installed acceptance and independent final findings.

Full Arc-equivalent, accessibility, extension and protected-streaming acceptance remain separate from a source or fixture pass. Record unresolved findings rather than treating a critic’s withheld preference as approval.

## Violet review loop

The 1.0.3 preview uses one implementer and three **GPT-6 Luna / xhigh** read-only critics. REA/CDP captures and Playwright interactions review the exact Rust renderer with clearly identified fixture data; separate macOS CI checks exercise the compiled shell and adapters.

The baseline criticism identified the cream/serif promotional palette, excessive command dialogs, small contextual targets, hidden module management and disconnected providers. Violet uses charcoal/neutral surfaces, violet selection, direct address/search inputs, persistent Library/Modules destinations and anchored menus. Spaces/folders support dragging and keyboard reordering; horizontal sidebar scrolling switches Spaces. Setup has step transitions, reduced-motion behavior, live layout illustration and module defaults.

The first revised code critique found Focus Escape/address recovery, incomplete icon symbol resolution and a cross-Profile Space boundary. These were corrected at the reducer/host boundaries; validated SF Symbols are rasterized by AppKit and used as inert masks in Rust controls. UI criticism led to opt-in start tips, prominent module-use actions, larger tab/folder targets and a simpler setup scene. UX checks verified retained setup choices and module settings; setup toggles now expose switch semantics and the review includes enabled tools. Resource workers run only while their Rust monitor screen is open, and stop on module replacement or shell teardown.

Mac compilation, native tests, installed acceptance, signing availability and independent full Blink results remain separate evidence. A visually improved fixture does not establish full Arc parity or a notarized distribution.
