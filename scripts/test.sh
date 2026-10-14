#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-rust.sh
cargo test --locked --workspace
python3 scripts/test-installed-acceptance.py
python3 scripts/test-core-acceptance.py
python3 scripts/test-disk-images.py
python3 scripts/test-chromium-updates.py
python3 scripts/test-appcast.py
if [[ "$(uname -s)" == Darwin ]]; then
  configuration=debug
  previous_argument=""
  for argument in "$@"; do
    if [[ "$previous_argument" == -c || "$previous_argument" == --configuration ]]; then configuration="$argument"; fi
    previous_argument="$argument"
  done
  ./scripts/build-workers.sh "$configuration"
  python3 scripts/native-tests.py "$@"
else
  swift test "$@"
fi
python3 scripts/validate-packages.py
