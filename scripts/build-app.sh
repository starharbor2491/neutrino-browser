#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Building Neutrino.app requires macOS 14+ and Xcode 16+ (or Swift 6 command-line tools).' >&2
  exit 1
fi
configuration="${CONFIGURATION:-release}"
./scripts/build-rust.sh
if [[ "$configuration" != release && "$configuration" != debug ]]; then
  echo 'CONFIGURATION must be release or debug.' >&2
  exit 1
fi
# The shipped application and every bundled worker target Apple Silicon.
for product in Neutrino NeutrinoResourceMonitor NeutrinoMemoryMonitor NeutrinoReaderWorker NeutrinoUpdater; do
  swift build -c "$configuration" --product "$product" --triple arm64-apple-macosx14.0
done
arm_binary_directory="$(swift build -c "$configuration" --triple arm64-apple-macosx14.0 --show-bin-path)"
app_directory="$PWD/dist/Neutrino.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources/Legal"
cp "$arm_binary_directory/Neutrino" "$app_directory/Contents/MacOS/Neutrino"
lipo "$app_directory/Contents/MacOS/Neutrino" -verify_arch arm64
rm -rf "$app_directory/Contents/Resources/Modules"
cp -R Sources/NeutrinoApp/Resources/Modules "$app_directory/Contents/Resources/Modules"
for worker in NeutrinoResourceMonitor NeutrinoMemoryMonitor NeutrinoReaderWorker; do
  case "$worker" in
    NeutrinoResourceMonitor) module_id=org.neutrino.resource-monitor ;;
    NeutrinoMemoryMonitor) module_id=org.neutrino.memory-monitor ;;
    NeutrinoReaderWorker) module_id=org.neutrino.reader ;;
  esac
  payload="$app_directory/Contents/Resources/Modules/$module_id/worker"
  cp "$arm_binary_directory/$worker" "$payload"
  chmod 755 "$payload"
  codesign --force --sign - "$payload"
  codesign --verify --strict "$payload"
done
cp Resources/Info.plist "$app_directory/Contents/Info.plist"
rm -rf "$app_directory/Contents/Resources/Updater"
mkdir -p "$app_directory/Contents/Resources/Updater/arm64"
cp "$arm_binary_directory/NeutrinoUpdater" "$app_directory/Contents/Resources/Updater/arm64/NeutrinoUpdater"
codesign --force --sign - --identifier org.neutrino.updater "$app_directory/Contents/Resources/Updater/arm64/NeutrinoUpdater"
cp LICENSE COPYING.MPL docs/LICENSING.md "$app_directory/Contents/Resources/Legal/"
swift scripts/build-icon.swift dist/AppIcon.iconset
iconutil -c icns dist/AppIcon.iconset -o "$app_directory/Contents/Resources/AppIcon.icns"
# A complete build includes Blink. The explicit WebKit-only mode exists solely
# for shell development/tests and cannot be published as a complete installer.
rm -rf "$app_directory/Contents/Frameworks/Chromium.neutrinoengine"
if [[ "${NEUTRINO_WEBKIT_DEVELOPMENT_ONLY:-0}" != 1 ]]; then
  if [[ -z "${NEUTRINO_CHROMIUM_PACKAGE:-}" ]]; then
    runtime_work="$PWD/.build/cef-runtime"
    python3 scripts/chromium-runtime.py --arch arm64 --work-dir "$runtime_work"
    chromium_package="$runtime_work/Chromium-arm64.neutrinoengine"
  else
    chromium_package="$NEUTRINO_CHROMIUM_PACKAGE"
  fi
  python3 scripts/chromium-runtime.py --embed-package "$chromium_package" --app "$app_directory"
fi
python3 scripts/distribution-metadata.py "$app_directory"
# Consumer signing is explicit and fails closed if an identity is unavailable.
# Local/CI builds retain ad-hoc signatures. Explicit published previews use
# GitHub provenance/code seals; consumer updates retain Developer ID trust.
if [[ -n "${NEUTRINO_SIGNING_IDENTITY:-}" ]]; then
  python3 scripts/sign-release.py "$app_directory"
else
  codesign --force --sign - "$app_directory"
fi
codesign --verify --strict "$app_directory"
if otool -L "$app_directory/Contents/MacOS/Neutrino" | grep -E '/workspace|/tmp/neutrino' >/dev/null; then
  echo 'The executable has an unexpected development dependency.' >&2
  exit 1
fi
echo "Built $app_directory"
