# Blink integration

Neutrino owns the tabs, address bar, workspace rail, start surface, and navigation controls for both engines. Blink is the default; WebKit remains an alternative with a separate website store.

## Host boundary

The bridge uses upstream CEF Chrome-style Views: a `CefBrowserView` in a frameless `CefWindow`, with `CEF_CTT_NONE`. Its Cocoa window follows a Neutrino page anchor as a managed child. Rendering stays in Chromium's process model and sandbox. The integration does not replace Chromium's rendering or browser internals.

One Neutrino tab owns one live engine adapter. Spaces share descriptors across windows; selecting elsewhere transfers the existing adapter/native surface rather than creating a second document. Background Space adapters retain their original Profile and callbacks. Popups must preserve original POST/opener state while becoming Neutrino tabs. These are source implementations requiring macOS acceptance.

The bridge ABI is **7**, manifest format **2**, and `runtimeStyle` is **chromeViews**. Old normal-Chrome-window packages are rejected. The pinned upstream CEF distribution is `154.0.34+g14c5a08+chromium-154.0.8037.98`, [commit 14c5a08](https://github.com/chromiumembedded/cef/commit/14c5a089e8452874cb1a556dc3fde26ed2d87723).

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
