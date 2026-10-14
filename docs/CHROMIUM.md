# Blink integration

Neutrino owns the tabs, address bar, workspace rail, start surface, and navigation controls for both engines. Blink is the default; WebKit remains an alternative with a separate website store.

## Host boundary

The bridge creates a normal upstream CEF Chrome-style browser window. CEF Views forces popup-type windows, which Chromium rejects for extension action popups. A macOS clip view positions the native toolbar and tab strip above the visible page viewport while leaving their upstream services intact. The child window follows Neutrino’s native page anchor; geometry acceptance checks the actual WebContents viewport. Rendering stays in Chromium’s process model and sandbox. No rendering or browser-internals fork is maintained.

One Neutrino tab owns one live engine adapter. Spaces share descriptors across windows; selecting elsewhere transfers the existing adapter/native surface rather than creating a second document. Background Space adapters retain their original Profile and callbacks. Popups must preserve original POST/opener state while becoming Neutrino tabs. These are source implementations requiring macOS acceptance.

The bridge ABI is **8**, manifest format **2**, and `runtimeStyle` remains **chromeViews** and `hostPresentation` is **clippedNative**. Predecessor Views and stock-window packages are rejected. The pinned upstream CEF distribution is `154.0.34+g14c5a08+chromium-154.0.8037.98`, [commit 14c5a08](https://github.com/chromiumembedded/cef/commit/14c5a089e8452874cb1a556dc3fde26ed2d87723).

## Compatibility gates

CEF Chrome style provides browser services, but removing Chrome's toolbar does not establish complete extension compatibility. Action popups, side panels, extension-created tabs/windows, permission approval, and Web Store installation need verified Neutrino surfaces. Some APIs assume Chrome's toolbar or window/tab ownership; narrow upstream integration patches may be necessary.

The retained MV3 fixture tests content scripts, service workers, scripting, storage, permissions, actions, options, side panels, update, disable, removal, and native tab/window identity. Toolbar-dependent or extension-group tests remain compatibility gates. Do not delete failing requirements or present hidden stock controls as equivalent Neutrino features.

Persistent CEF contexts are per Profile. Private windows use separate nonpersistent contexts and do not inherit regular extensions. WebKit data remains separate. Explicit engine switching reloads a safe website URL; cookies, POST state, forms, and execution state do not transfer. WebKit does not promise Chrome-extension parity.

## Local services

Downloads use retained destination/cancel/staging ownership services. An incomplete writer remains owned until terminal acknowledgement or genuine engine shutdown. Extension background downloads still require their own acceptance.

Reader/page assistance/login filling use isolated engine worlds and bounded results. Blocking currently uses a small bundled domain list for subresources, not a full filter-list engine. Site-permission controls, complete password/autofill flows, media, and performance controls remain tracked in [PARITY.md](PARITY.md).

Protected streaming is a required core gate. This checkout does not bundle a licensed Widevine CDM or establish protected playback. CDM/codec rights and representative playback must be resolved before declaring core complete.

## Build

On an Apple Silicon Mac with Swift 6, Xcode, CMake, and Python:

```sh
./scripts/build-app.sh
open dist/Neutrino.app
```

The build obtains the pinned ARM64 CEF package when no `NEUTRINO_CHROMIUM_PACKAGE` is supplied. End users install a complete offline app and do not run these commands. `NEUTRINO_WEBKIT_DEVELOPMENT_ONLY=1` creates an explicitly incomplete development build.

The framework, five helper variants, resources/locales, and notices remain inside the sealed app. Runtime updates use verified whole-app replacement, not mutation of a running signed bundle. TLS, sandboxing, Gatekeeper, and library validation remain enabled.

## Validation status

Linux checks validate portable state and source syntax, not this Cocoa/CEF integration. Native build/type checking, child-window geometry/focus, document transfer, extension workflows, media permissions, clean-Mac installation, and ordinary shutdown must run on macOS. Earlier Radius acceptance is historical and does not certify this new host.

The `chromeViews` manifest family label is retained for complete-application updates from existing previews. ABI 8 and `hostPresentation=clippedNative` identify the actual new hosting integration; the replacement host enforces both. This does not allow predecessor engine packages to load in Studio.
