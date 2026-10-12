#!/usr/bin/env bash
# Records the eight real venues for a while with examples/mainnet-all.sexp, checks the
# output and stops the recorder. Needs network access; run from the repo inside the
# multi-repo dune workspace.
set -euo pipefail

seconds=${1:-90}
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/.." && pwd)
build=${DUNE_BUILD_DIR:-$root/_build}
out=/tmp/market-recorder-mainnet

if lsof -iTCP:9920 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port 9920 is busy" >&2
  exit 1
fi

(cd "$root" && opam exec --switch 5.2.0+ox -- dune build ./market-recorder/bin/main.exe)

rm -rf "$out"
mkdir -p "$out/logs"
"$build/default/market-recorder/bin/main.exe" run -config "$here/examples/mainnet-all.sexp" \
  2>"$out/logs/recorder.log" &
recorder=$!
trap 'kill "$recorder" 2>/dev/null || true' EXIT
sleep "$seconds"

echo "== /healthz"
curl -s -w '%{http_code}\n' localhost:9920/healthz
echo "== /metrics"
curl -s localhost:9920/metrics >"$out/metrics.txt"
grep -v '^#' "$out/metrics.txt"

kill -TERM "$recorder"
status=0
wait "$recorder" || status=$?
echo "== recorder exit $status"

echo "== files"
(cd "$out/data" && find . -type f | sort)
echo "== remote"
(cd "$out/remote" && find . -type f | sort)
