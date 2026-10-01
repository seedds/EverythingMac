#!/bin/bash
# Compares EverythingMac's search engine with Cardinal 0.1.23's on this Mac, for
# docs/PERFORMANCE.md#compared-with-cardinal-0123. Both index the same scope: `/`
# without /System/Volumes/Data and without other volumes, which EverythingMac
# skips and Cardinal 0.1.23 walks into. Rounds alternate which engine runs first.
# Raw results go to build/compare-cardinal/results.jsonl, then a summary is printed.
# Usage: scripts/compare-cardinal/run.sh [ROUNDS] [SEARCH_RUNS]
set -euo pipefail
cd "$(dirname "$0")/../.."
ROUNDS=${1:-3}
REPS=${2:-5}
OUT=build/compare-cardinal
CARDINAL=build/cardinal-0.1.23
export PATH="$HOME/.cargo/bin:$PATH"
mkdir -p "$OUT"

[ -d "$CARDINAL" ] ||
  git clone --quiet --depth 1 --branch v0.1.23 https://github.com/cardisoft/cardinal.git "$CARDINAL"
# Cardinal's workspace leaves its engine to the app's own workspace, so build the
# timing program as a separate crate, pinned to the versions Cardinal's app locks.
HARNESS=$OUT/cardinal-harness
mkdir -p "$HARNESS"
cat >"$HARNESS/Cargo.toml" <<EOF
[package]
name = "cardinal-timing"
version = "0.1.0"
edition = "2024"

[[bin]]
name = "cardinal_timing"
path = "$PWD/scripts/compare-cardinal/cardinal_timing.rs"

[dependencies]
search-cache = { path = "$PWD/$CARDINAL/search-cache" }
search-cancel = { path = "$PWD/$CARDINAL/search-cancel" }

[workspace]
EOF
[ -f "$HARNESS/Cargo.lock" ] || cp "$CARDINAL/cardinal/src-tauri/Cargo.lock" "$HARNESS/Cargo.lock"
cargo build --release --quiet --manifest-path "$HARNESS/Cargo.toml"
cargo build --locked --release --quiet -p search-cache --example compare_timing
CARDINAL_BIN=$HARNESS/target/release/cardinal_timing
EVERYTHING_BIN=target/release/examples/compare_timing

IGNORES=(/System/Volumes/Data)
while IFS= read -r mount; do IGNORES+=("$mount"); done < <("$EVERYTHING_BIN" mounts / -)
QUERIES=(report e '*.swift' 'ext:pdf' 'infolder:/Applications plist' '')

RESULTS=$OUT/results.jsonl
: >"$RESULTS"
# Runs one engine operation as its own process and records its peak memory.
run() {
  local engine=$1 round=$2 op=$3
  shift 3
  local bin=$CARDINAL_BIN index=$OUT/cardinal.db
  if [ "$engine" = everythingmac ]; then bin=$EVERYTHING_BIN index=$OUT/everythingmac.db; fi
  local load
  load=$(sysctl -n vm.loadavg | awk '{print $2}')
  local stderr=$OUT/time.txt
  local lines
  case $op in
  query) lines=$(/usr/bin/time -l "$bin" query / "$index" "$REPS" "${IGNORES[@]}" -- "${QUERIES[@]}" 2>"$stderr") ;;
  *) lines=$(/usr/bin/time -l "$bin" "$op" / "$index" "${IGNORES[@]}" 2>"$stderr") ;;
  esac
  local rss
  rss=$(awk '/maximum resident set size/ {print $1}' "$stderr")
  while IFS= read -r line; do
    echo "${line%\}},\"round\":$round,\"peak_rss_bytes\":$rss,\"load_average\":$load}" >>"$RESULTS"
  done <<<"$lines"
}

# The first scans warm the filesystem caches and are not recorded.
"$CARDINAL_BIN" scan / "$OUT/cardinal.db" "${IGNORES[@]}" >/dev/null
"$EVERYTHING_BIN" scan / "$OUT/everythingmac.db" "${IGNORES[@]}" >/dev/null
for round in $(seq 1 "$ROUNDS"); do
  if [ $((round % 2)) = 1 ]; then order=(cardinal everythingmac); else order=(everythingmac cardinal); fi
  for op in scan load query; do
    for engine in "${order[@]}"; do run "$engine" "$round" "$op"; done
  done
done

python3 - "$RESULTS" <<'EOF'
import json, statistics, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
def values(engine, op, key, query=None):
    return [r[key] for r in rows if r["engine"] == engine and r["op"] == op
            and (query is None or r.get("query") == query)]
def show(label, op, key, query=None, unit="ms", scale=1.0):
    c, e = values("cardinal", op, key, query), values("everythingmac", op, key, query)
    mc, me = statistics.median(c) * scale, statistics.median(e) * scale
    rng = lambda v: f"{min(v) * scale:.4g}–{max(v) * scale:.4g}"
    print(f"| {label} | {mc:.4g} {unit} ({rng(c)}) | {me:.4g} {unit} ({rng(e)}) | {mc / me:.1f}× |")
print("| Operation | Cardinal 0.1.23 | EverythingMac | Ratio |")
print("| --- | --- | --- | --- |")
show("Full scan", "scan", "scan_ms", unit="s", scale=1 / 1000)
show("Full scan, peak memory", "scan", "peak_rss_bytes", unit="MiB", scale=1 / 2**20)
show("Saving the index", "scan", "save_ms")
show("Index file size", "scan", "index_bytes", unit="MiB", scale=1 / 2**20)
show("Opening the saved index", "load", "load_ms")
show("Opening, peak memory", "load", "peak_rss_bytes", unit="MiB", scale=1 / 2**20)
for query in dict.fromkeys(r["query"] for r in rows if r["op"] == "query"):
    show(f"Search `{query}`" if query else "Search (empty query)", "query", "median_ms", query)
print()
for engine in ("cardinal", "everythingmac"):
    entries = sorted(set(values(engine, "scan", "entries") + values(engine, "load", "entries")))
    counts = {r["query"]: r["results"] for r in rows if r["engine"] == engine and r["op"] == "query"}
    print(f"{engine}: entries {entries}, results {counts}")
loads = [r["load_average"] for r in rows]
print(f"load average (5 min) {min(loads)}–{max(loads)}")
EOF
