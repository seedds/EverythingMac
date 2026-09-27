#!/bin/bash
set -euo pipefail
PROTOTYPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${CARDINAL_TAURI_REPO:-$(dirname "$PROTOTYPE_DIR")/cardinal}"
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTC="$HOME/.cargo/bin/rustc"
export CARGO_PROFILE_RELEASE_STRIP=none
export CARDINAL_BENCHMARK_INDEX="${1:-$HOME/Library/Application Support/com.cardinal.one/cardinal.db}"
export CARDINAL_BENCHMARK_OUTPUT="${2:-$PROTOTYPE_DIR/build/tauri-benchmark.json}"
CARDINAL_BENCHMARK_INDEX="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$CARDINAL_BENCHMARK_INDEX")"
CARDINAL_BENCHMARK_OUTPUT="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$CARDINAL_BENCHMARK_OUTPUT")"
export VITE_NATIVE_PROTOTYPE_BENCHMARK=1
mkdir -p "$PROTOTYPE_DIR/build"
cd "$REPO_DIR/cardinal"
# Unique identity isolates preferences/permissions from the installed application.
npm run tauri build -- --no-bundle --features native-prototype-benchmark --config '{"identifier":"com.cardinal.native-baseline","productName":"Cardinal Benchmark Baseline"}'
"$PROTOTYPE_DIR/scripts/package-baseline.sh"
if [[ "${3:-}" == "--build-only" ]]; then exit 0; fi
exec "$PROTOTYPE_DIR/build/Cardinal Tauri Baseline.app/Contents/MacOS/cardinal"
