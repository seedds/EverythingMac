#!/bin/bash
set -euo pipefail
PROTOTYPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Upstream Cardinal checkout paths retain their original names; see UPSTREAM.md.
REPO_DIR="${EVERYTHING_MAC_TAURI_REPO:-$(dirname "$PROTOTYPE_DIR")/cardinal}"
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTC="$HOME/.cargo/bin/rustc"
export CARGO_PROFILE_RELEASE_STRIP=none
export EVERYTHING_MAC_BENCHMARK_INDEX="${1:-$HOME/Library/Application Support/com.everything.mac/everything-mac.db}"
export EVERYTHING_MAC_BENCHMARK_OUTPUT="${2:-$PROTOTYPE_DIR/build/tauri-benchmark.json}"
EVERYTHING_MAC_BENCHMARK_INDEX="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$EVERYTHING_MAC_BENCHMARK_INDEX")"
EVERYTHING_MAC_BENCHMARK_OUTPUT="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$EVERYTHING_MAC_BENCHMARK_OUTPUT")"
# Compatibility with the historical upstream Cardinal benchmark instrumentation.
export CARDINAL_BENCHMARK_INDEX="$EVERYTHING_MAC_BENCHMARK_INDEX"
export CARDINAL_BENCHMARK_OUTPUT="$EVERYTHING_MAC_BENCHMARK_OUTPUT"
export VITE_NATIVE_PROTOTYPE_BENCHMARK=1
mkdir -p "$PROTOTYPE_DIR/build"
cd "$REPO_DIR/cardinal"
# Unique identity isolates preferences/permissions from the installed application.
npm run tauri build -- --no-bundle --features native-prototype-benchmark --config '{"identifier":"com.everything.mac-baseline","productName":"EverythingMac Benchmark Baseline"}'
"$PROTOTYPE_DIR/scripts/package-baseline.sh"
if [[ "${3:-}" == "--build-only" ]]; then exit 0; fi
exec "$PROTOTYPE_DIR/build/EverythingMac Tauri Baseline.app/Contents/MacOS/everything-mac"
