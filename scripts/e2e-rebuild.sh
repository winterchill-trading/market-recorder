#!/usr/bin/env bash
# Records the three simulators with scripts/e2e-sims.sh, rebuilds the recorded day's
# norm/ event logs from raw/ with `market-recorder rebuild-norm` into a fresh directory
# and compares them with the logs the recorder wrote live: the same files, the same
# event counts (`market-data dump`) and the same bytes.
#
# The recorder's L2 snapshot index (norm/l2/_snapshots/) is not rebuilt: rebuild-norm
# writes event logs only (Market_data.Rebuild_norm has no snapshot interval), so those
# files are listed and left out of the comparison.
#
# Usage: scripts/e2e-rebuild.sh [SECONDS] [-skip VENUE:STREAM ...]
# A skipped raw stream's event logs are left out of the comparison (for Hyperliquid,
# skipping l2 also drops bbo, which comes from the l2 frames).
set -euo pipefail

seconds=20
if [[ ${1:-} =~ ^[0-9]+$ ]]; then
  seconds=$1
  shift
fi
skip_args=("$@")
here=$(cd "$(dirname "$0")/.." && pwd)
root=${WORKSPACE:-$(cd "$here/.." && pwd)}
build=${DUNE_BUILD_DIR:-$root/_build}
out=/tmp/market-recorder-sims

"$here/scripts/e2e-sims.sh" "$seconds"

(cd "$root" && opam exec --switch 5.2.0+ox -- dune build --root . \
  ./market-data/bin/market_data_cli.exe ./market-recorder/bin/main.exe)
recorder_exe=$build/default/market-recorder/bin/main.exe
md_exe=$build/default/market-data/bin/market_data_cli.exe

problems=()
problem() {
  echo "PROBLEM: $*" >&2
  problems+=("$*")
}

dates=$(cd "$out/data/raw" && find . -name '*.ndjson*' | awk -F/ '{ print $5 "-" $6 "-" $7 }' | sort -u)
rm -rf "$out/rebuilt"
for date in $dates; do
  echo "== rebuild-norm $date ${skip_args[*]+"${skip_args[*]}"}"
  "$recorder_exe" rebuild-norm -data-dir "$out/data" -out "$out/rebuilt/$date" \
    -date "$date" ${skip_args[@]+"${skip_args[@]}"} | tee "$out/rebuild-$date.sexp"
  grep -q '(frame_errors 0)' "$out/rebuild-$date.sexp" || problem "$date: rejected frames"

  recorded=$(cd "$out/data" && find . -path "*/norm/*/$date.bin" -not -path '*/_snapshots/*' | sort)
  (cd "$out/data" && find . -path "*/_snapshots/$date.bin" | sort | sed 's/^/not rebuilt: /')
  rebuilt=$(cd "$out/rebuilt/$date" && find . -name '*.bin' | sort)
  for f in $recorded; do
    if [[ ! -f $out/rebuilt/$date/$f ]]; then
      IFS=/ read -r _ venue _ _ stream _ <<<"$f"
      raw_stream=$stream
      [[ $venue/$stream == hyperliquid/bbo ]] && raw_stream=l2
      if [[ " ${skip_args[*]+"${skip_args[*]}"} " == *" $venue:$raw_stream "* ]]; then
        echo "skipped $f"
      else
        problem "not rebuilt: $f"
      fi
      continue
    fi
    a=$("$md_exe" dump "$out/data/$f" | wc -l | tr -d ' ')
    b=$("$md_exe" dump "$out/rebuilt/$date/$f" | wc -l | tr -d ' ')
    if cmp -s "$out/data/$f" "$out/rebuilt/$date/$f"; then
      echo "same   $f ($a events)"
    else
      problem "$f differs: recorded $a events, rebuilt $b"
      diff <("$md_exe" dump "$out/data/$f") <("$md_exe" dump "$out/rebuilt/$date/$f") |
        head -5 | cut -c1-200 || true
    fi
  done
  for f in $rebuilt; do
    [[ -f $out/data/$f ]] || problem "rebuilt but never recorded: $f"
  done
done

if ((${#problems[@]} > 0)); then
  echo "== FAILED: ${#problems[@]} problem(s)" >&2
  exit 1
fi
echo "== OK"
