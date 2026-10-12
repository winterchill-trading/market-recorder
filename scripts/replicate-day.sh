#!/usr/bin/env bash
# Fetches one UTC day of raw minute files from two collectors' stores with rclone and
# merges them with `market-recorder merge` into one canonical copy.
#
# Usage: scripts/replicate-day.sh REMOTE_A REMOTE_B [YYYY-MM-DD] [merge flags...]
#   REMOTE_A/REMOTE_B are rclone paths holding each collector's raw/ tree, i.e. the
#   uploader's destination without {rel} (e.g. s3-tokyo:md-raw/collector-a). DATE
#   defaults to yesterday (UTC). Extra flags go to merge (e.g. -window 2s).
#   $WORK (default ./replicate/DATE) receives a/, b/ and out/; out/ holds the merged
#   raw/ and _merge/DATE.json. With $DEST set (an rclone path) out/ is copied there.
#   a/ and b/ are removed after a successful merge unless KEEP_INPUT=1.
#   $RCLONE overrides the rclone binary; the recorder binary is $MARKET_RECORDER, else
#   `market-recorder` on PATH, else the one built from this checkout.
set -euo pipefail

if (($# < 2)); then
  sed -n '2,14p' "$0" >&2
  exit 2
fi
remote_a=$1
remote_b=$2
shift 2
if [[ ${1:-} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  date=$1
  shift
else
  date=$(date -u -v-1d +%F 2>/dev/null || date -u -d yesterday +%F)
fi
work=${WORK:-replicate/$date}
rclone=${RCLONE:-rclone}
day_path=${date//-//}

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

mkdir -p "$work/a" "$work/b"
for side in a b; do
  if [[ $side == a ]]; then remote=$remote_a; else remote=$remote_b; fi
  echo "fetching $date from $remote" >&2
  "$rclone" copy "$remote" "$work/$side" --include "/raw/*/*/*/$day_path/**"
done

echo "merging into $work/out" >&2
"$exe" merge -a "$work/a" -b "$work/b" -out "$work/out" -date "$date" "$@"

if [[ -n ${DEST:-} ]]; then
  echo "copying merged day to $DEST" >&2
  "$rclone" copy "$work/out" "$DEST"
fi
if [[ ${KEEP_INPUT:-0} != 1 ]]; then
  rm -rf "$work/a" "$work/b"
fi
