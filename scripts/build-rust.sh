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
cp .build/rust-target/release/libneutrino_shell.a .build/rust/libneutrino_shell.a
