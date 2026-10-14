#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v cargo >/dev/null 2>&1; then
  echo 'Rust is required. Install the stable toolchain from https://rustup.rs, then retry.' >&2
  exit 1
fi
cargo build --locked --release --lib -p neutrino-shell --target-dir .build/rust-target
mkdir -p .build/rust
if ! cmp -s .build/rust-target/release/libneutrino_shell.a .build/rust/libneutrino_shell.a; then
  cp .build/rust-target/release/libneutrino_shell.a .build/rust/libneutrino_shell.a
  # SwiftPM does not track archives passed through a system-library modulemap.
  # Invalidate only linked products, keeping compiled Swift objects. SwiftPM's
  # incremental compiler can produce identical adapter objects after a touch;
  # missing product outputs reliably force linking the new Rust archive.
  for variant in .build/*/debug .build/*/release; do
    for product in Neutrino NeutrinoReaderWorker NeutrinoResourceMonitor NeutrinoMemoryMonitor NeutrinoUpdater NeutrinoPackageTests.xctest; do
      rm -rf "$variant/$product"
    done
  done
fi
