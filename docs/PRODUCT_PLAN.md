# Neutrino product brief

Confirmed with the product owner on 11 October 2026 after a 21-question interview. This replaces the previous WebKit-first, optional-Chromium direction.

Neutrino is an Apple Silicon macOS browser with an Arc-inspired interface, Vivaldi/Shift customization, and Helium/Safari restraint. Neutrino owns the visible browser interface independently of its rendering engine. Use a deliberate design system; native operating-system permission and security dialogs remain appropriate.

The implementation direction is Rust for portable product logic and interface rendering, with Swift confined progressively to required macOS integration. Preserve working engine, privacy, storage, module and distribution infrastructure while migrating it deliberately. Use REA and an independent code/UI/UX gauntlet against Arc; implementation stays with one coder. The supplied `neutrino.svg` is the source artwork for the application icon.

## Core experience

The core milestone includes navigation, tabs, Spaces, Profiles, folders, split view, bookmarks, history, downloads, private browsing, extensions, local passwords/autofill, ad/tracker blocking, the visual editor, guided setup, and a complete offline installer. Protected streaming must pass actual service playback before the core release is called complete.

Spaces organize tabs and folders. Profiles isolate website sign-ins, cookies, extensions, and browsing data. Several Spaces can share one Profile. Windows share a Space's tab list. Each live tab appears in one window or pane at a time. Selecting it elsewhere transfers its existing document; Duplicate creates another tab. Regular tabs restore, pinned/folder tabs persist, optional idle archiving is recoverable, and private tabs are temporary.

The default is a quiet vertical workspace rail, compact navigation, and a framed page canvas. Verify narrow/wide windows, light/dark appearance, keyboard access, reduced motion, increased contrast, VoiceOver, and IME input.

## Editing and customization

Provide direct selection, dragging, resizing, removal, replacement, and styling in flexible top/bottom/left/right docking regions and panels. Include live preview, undo, named setups, app defaults, and per-Space assignments. Retain detailed typography, spacing, color, density, icon, border, and per-component appearance controls.

Site identity, security information, permission confirmations, and recovery must remain reachable. Every editor state has an exit/reset path. Removing UI does not delete its data.

## Engines and add-ons

Blink through upstream Chromium/CEF is the default. WebKit remains available through the same interface, with separate website state and documented extension limitations. Follow upstream releases; small maintained integration patches are allowed. Do not maintain a separate rendering-engine fork.

Chrome-style CEF Views is the current custom-host candidate. Views alone does not establish parity with a normal Chrome window: toolbar-dependent extension APIs, actions/popups, side panels, and Web Store installation require explicit integration and acceptance.

Bundle first-party modules, support local module imports, and allow Chrome Web Store/local extension installation. There is no Neutrino store.

## Setup and distribution

Complete guided setup before browsing: Profiles/Spaces, supported browser-data import, layout/theme, search/privacy, built-in features, optional AI, and review. Required choices have sensible defaults; import and AI are optional. Describe formats actually supported. Initial import supports exported HTML bookmarks, not passwords, cookies, or complete browser profiles.

Ship one self-contained Apple Silicon macOS installer containing every required engine, helper, updater, and module payload. Setup works offline. The default source build includes Blink; explicit WebKit-only builds are incomplete development tools.

No legacy Radius migration is required. Rename current product identities to Neutrino while preserving actual repository URLs and truthful historical provenance.

## AI

AI is off until configured. Support API keys and local compatible endpoints; store secrets in macOS Keychain. Share page/tab content only through explicit actions. Proactive features require separate opt-in. Initial scope is selected-text/page questions, summaries, and requested tab/Space organization proposals, applied only on explicit request. General navigation/form/task agents come later.

Use officially supported OpenAI and xAI account OAuth with Neutrino's own identity. OpenAI's documented OSS dynamic registration supports an own-client path: PKCE, loopback validation, signed identity/claims validation, granted scopes, refresh/revocation, model discovery, and public Responses API requests. xAI own-client registration and inference entitlements still need verification. Never borrow another application's client identity.

## Delivery and finished target

Deliver a complete core experience first, then verified equivalent workflows for every locally runnable capability of Arc, Chrome, and Opera/Opera GX. No hosted sync, VPN, cloud storage, or Neutrino store. Optional AI services and extension downloads are allowed.

| Stage | Required outcome |
| --- | --- |
| Custom engine boundary | One Neutrino tab per WebContents, own chrome, reliable popup/opener/privacy/download/focus/shutdown behavior, real extension surfaces |
| Complete core | Polished daily browsing, workspaces, editing, setup, passwords/autofill, blocking, protected streaming |
| Complete installer | Apple Silicon payload closure, signing/notarization, offline clean-Mac setup, update trust/recovery |
| Verified local parity | Local Arc workflows, Chrome APIs/tools, Opera workflows, enforceable GX controls, advanced customization |

[PARITY.md](PARITY.md) tracks implementation separately from verification. No blanket parity claim is valid until the checklist is complete with evidence tied to tested source/binaries.

## Release gates

- macOS compilation, native integration, visual/accessibility acceptance, and installed-app tests on this new build.
- Chrome Store/local installs, workers, permissions, actions/popups, options, side panels, restart persistence, and removal in the custom host.
- Licensed Widevine/CDM and media-codec distribution plus actual representative protected streaming.
- Native OpenAI account acceptance and a supported own-client xAI integration.
- Developer ID signing/notarization, offline clean-Mac installation, and fail-closed updates.

The Linux workspace can validate portable state and parsing. It cannot establish these native/external gates. Historical predecessor receipts do not transfer to renamed binaries or the new host.
