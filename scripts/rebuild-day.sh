#!/usr/bin/env bash
# Rebuilds one UTC day of norm/ event logs from a recorder data directory's raw/ minute
# files with `market-recorder rebuild-norm`.
#
# Usage: scripts/rebuild-day.sh DATA_DIR [YYYY-MM-DD] [rebuild-norm flags...]
#   DATE defaults to yesterday (UTC). The output goes to $OUT, default
#   DATA_DIR/rebuilt/DATE, which must be new or empty. Extra flags are passed through,
#   e.g. -venue binance or -skip bybit:l2.
#   The binary is $MARKET_RECORDER, else `market-recorder` on PATH, else the one built
#   from this checkout inside the multi-repo dune workspace.
set -euo pipefail

if (($# < 1)); then
  sed -n '2,11p' "$0" >&2
  exit 2
fi
data_dir=$1
shift
if [[ ${1:-} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  date=$1
  shift
else
  date=$(date -u -v-1d +%F 2>/dev/null || date -u -d yesterday +%F)
fi
out=${OUT:-$data_dir/rebuilt/$date}

if [[ -n ${MARKET_RECORDER:-} ]]; then
  exe=$MARKET_RECORDER
elif command -v market-recorder >/dev/null; then
  exe=market-recorder
else
  here=$(cd "$(dirname "$0")/.." && pwd)
  root=${WORKSPACE:-$(cd "$here/.." && pwd)}
  (cd "$root" && opam exec --switch 5.2.0+ox -- dune build --root . \
    ./market-recorder/bin/main.exe)
  exe=${DUNE_BUILD_DIR:-$root/_build}/default/market-recorder/bin/main.exe
fi

echo "rebuilding $date from $data_dir/raw into $out" >&2
"$exe" rebuild-norm -data-dir "$data_dir" -out "$out" -date "$date" "$@"
