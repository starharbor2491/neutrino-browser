#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
if [[ "$configuration" != debug && "$configuration" != release ]]; then
  echo 'Worker configuration must be debug or release.' >&2
  exit 1
fi
if [[ $# -gt 0 ]]; then shift; fi
if [[ "$(uname -s)" == Darwin && "$(uname -m)" != arm64 ]]; then
  echo 'Neutrino builds its shipped workers on Apple Silicon.' >&2
  exit 1
fi
cargo build --locked --release -p neutrino-shell --target-dir .build/rust-target \
  --bin neutrino-reader-worker --bin neutrino-resource-monitor --bin neutrino-memory-monitor
binary_directory="$(swift build -c "$configuration" "$@" --show-bin-path)"
mkdir -p "$binary_directory"
for worker in reader-worker resource-monitor memory-monitor; do
  case "$worker" in
    reader-worker) product=NeutrinoReaderWorker ;;
    resource-monitor) product=NeutrinoResourceMonitor ;;
    memory-monitor) product=NeutrinoMemoryMonitor ;;
  esac
  cp ".build/rust-target/release/neutrino-$worker" "$binary_directory/$product"
  chmod 755 "$binary_directory/$product"
  if [[ "$(uname -s)" == Darwin ]]; then
    codesign --force --sign - "$binary_directory/$product"
    codesign --verify --strict "$binary_directory/$product"
  fi
done
