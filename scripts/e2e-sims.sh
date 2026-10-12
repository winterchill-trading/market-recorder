#!/usr/bin/env bash
# Records the three simulators for a while with examples/sims.sexp, checks the output
# and stops everything. Run from the repo inside the multi-repo dune workspace (or set
# WORKSPACE to another workspace root holding the simulators and this repo; OPAM_SWITCH
# names the opam switch, 5.2.0+ox by default; CI passes its local switch).
#
# Fails (exit 1) when /healthz is not 200, a configured stream received no frame, an
# upload failed or is still pending, the recorder exits non-zero, or a stream has no
# compressed minute file, uploaded copy or event log.
set -euo pipefail

seconds=${1:-20}
here=$(cd "$(dirname "$0")/.." && pwd)
root=${WORKSPACE:-$(cd "$here/.." && pwd)}
build=${DUNE_BUILD_DIR:-$root/_build}
switch=${OPAM_SWITCH:-5.2.0+ox}
out=/tmp/market-recorder-sims
port=9910

for p in 3510 3520 3530 $port; do
  if lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $p is busy" >&2
    exit 1
  fi
done

(cd "$root" && opam exec --switch "$switch" -- dune build --root . \
  ./hl-sim/bin/main.exe ./binance-sim/bin/main.exe ./bybit-sim/bin/main.exe \
  ./market-recorder/bin/main.exe)
recorder_exe=$build/default/market-recorder/bin/main.exe

rm -rf "$out"
mkdir -p "$out/logs"
pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; }
trap cleanup EXIT

"$build/default/hl-sim/bin/main.exe" -port 3510 >"$out/logs/hl-sim.log" 2>&1 &
pids+=($!)
"$build/default/binance-sim/bin/main.exe" -port 3520 >"$out/logs/binance-sim.log" 2>&1 &
pids+=($!)
"$build/default/bybit-sim/bin/main.exe" -port 3530 >"$out/logs/bybit-sim.log" 2>&1 &
pids+=($!)
sleep 3

"$recorder_exe" run -config "$here/examples/sims.sexp" 2>"$out/logs/recorder.log" &
recorder=$!
pids+=("$recorder")
sleep "$seconds"

problems=()
problem() {
  echo "PROBLEM: $*" >&2
  problems+=("$*")
}

echo "== /healthz"
code=$(curl -s -o "$out/healthz.txt" -w '%{http_code}' "localhost:$port/healthz" || true)
cat "$out/healthz.txt" 2>/dev/null || true
[[ $code == 200 ]] || problem "/healthz returned $code"

echo "== /status"
curl -s "localhost:$port/status" | head -20 || true

echo "== status"
"$recorder_exe" status -url "http://localhost:$port" || problem "status command failed"
curl -s "localhost:$port/metrics" >"$out/metrics.txt" || true

# every configured stream: frames > 0
streams=$(grep '^market_recorder_frames_total{' "$out/metrics.txt" || true)
[[ -n $streams ]] || problem "no streams in /metrics"
while read -r line; do
  [[ -z $line ]] && continue
  value=${line##* }
  [[ $value != 0 ]] || problem "no frames: ${line% *}"
done <<<"$streams"
failures=$(awk '$1 == "market_recorder_upload_failures_total" { print $2 }' "$out/metrics.txt")
[[ ${failures:-0} == 0 ]] || problem "$failures upload command runs failed"
if grep -qs last_flush_error "$out/healthz.txt"; then problem "raw writer failed"; fi

kill -TERM "$recorder"
status=0
wait "$recorder" || status=$?
echo "== recorder exit $status"
[[ $status == 0 ]] || problem "recorder exited with $status"

echo "== files"
(cd "$out/data" && find . -type f | sort)
[[ ! -s $out/data/upload-pending.sexp || $(tr -d ' ()\n' <"$out/data/upload-pending.sexp") == "" ]] ||
  problem "uploads left pending: $(cat "$out/data/upload-pending.sexp")"

# each stream: a compressed minute, its uploaded copy and an event log
while read -r line; do
  [[ -z $line ]] && continue
  labels=${line#*\{}
  labels=${labels%%\}*}
  venue=$(sed -E 's/.*venue="([^"]*)".*/\1/' <<<"$labels")
  stream=$(sed -E 's/.*stream="([^"]*)".*/\1/' <<<"$labels")
  symbol=$(sed -E 's/.*symbol="([^"]*)".*/\1/' <<<"$labels")
  raw=raw/$venue/$stream/$symbol
  zst=$(find "$out/data/$raw" -name '*.ndjson.zst' 2>/dev/null | head -1 || true)
  [[ -n $zst ]] || problem "no compressed minute under $raw"
  [[ -n $(find "$out/remote/$raw" -name '*.ndjson.zst' 2>/dev/null | head -1) ]] ||
    problem "nothing uploaded under $raw"
  if [[ -n $zst ]]; then
    zstd -dc "$zst" >/dev/null || problem "corrupt $zst"
  fi
done <<<"$streams"

# every stream with normalized events, including those recorded under another stream
# (Hyperliquid bbo comes from the l2 frames): an event log
while read -r line; do
  [[ -z $line ]] && continue
  labels=${line#*\{}
  labels=${labels%%\}*}
  venue=$(sed -E 's/.*venue="([^"]*)".*/\1/' <<<"$labels")
  stream=$(sed -E 's/.*stream="([^"]*)".*/\1/' <<<"$labels")
  symbol=$(sed -E 's/.*symbol="([^"]*)".*/\1/' <<<"$labels")
  [[ ${line##* } != 0 ]] || problem "no events: ${line% *}"
  [[ -n $(find "$out/data/$venue/$symbol/norm/$stream" -name '*.bin' 2>/dev/null | head -1) ]] ||
    problem "no event log under $venue/$symbol/norm/$stream"
done <<<"$(grep '^market_recorder_events_total{' "$out/metrics.txt" || true)"

# client counters: no parse errors
while read -r line; do
  [[ -z $line ]] && continue
  [[ ${line##* } == 0 ]] || problem "parse errors: $line"
done <<<"$(grep '^market_recorder_parse_errors_total{' "$out/metrics.txt" || true)"

for f in $(find "$out/data/raw" -name '*.zst' | sort | head -3); do
  echo "== zstd -dc ${f#"$out"/data/} | head -2"
  zstd -dc "$f" | head -2 | cut -c1-200
done

if ((${#problems[@]} > 0)); then
  echo "== FAILED: ${#problems[@]} problem(s)" >&2
  exit 1
fi
echo "== OK"
