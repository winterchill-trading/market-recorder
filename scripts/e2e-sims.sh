#!/usr/bin/env bash
# Records the three simulators for a while with examples/sims.sexp, checks the output
# and stops everything. Run from the repo inside the multi-repo dune workspace.
set -euo pipefail

seconds=${1:-20}
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/.." && pwd)
build=${DUNE_BUILD_DIR:-$root/_build}
out=/tmp/market-recorder-sims

for port in 3510 3520 3530 9910; do
  if lsof -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $port is busy" >&2
    exit 1
  fi
done

(cd "$root" && opam exec --switch 5.2.0+ox -- dune build \
  ./hl-sim/bin/main.exe ./binance-sim/bin/main.exe ./bybit-sim/bin/main.exe \
  ./market-recorder/bin/main.exe)

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

"$build/default/market-recorder/bin/main.exe" run -config "$here/examples/sims.sexp" \
  2>"$out/logs/recorder.log" &
recorder=$!
pids+=("$recorder")
sleep "$seconds"

echo "== /healthz"
curl -s -w '%{http_code}\n' localhost:9910/healthz
echo "== /metrics"
curl -s localhost:9910/metrics >"$out/metrics.txt"
grep -v '^#' "$out/metrics.txt"

kill -TERM "$recorder"
wait "$recorder"
echo "== recorder exit $?"

echo "== files"
(cd "$out/data" && find . -type f | sort)
echo "== remote"
(cd "$out/remote" && find . -type f | sort)
for f in $(find "$out/data/raw" -name '*.zst' | sort | head -3); do
  echo "== zstd -dc ${f#"$out"/data/} | head -2"
  zstd -dc "$f" | head -2 | cut -c1-200
done
