#!/usr/bin/env bash
# Runs replicate-day.sh over two local collector trees with a stand-in for rclone that
# copies directories, and checks the merged files and report.
#
# Usage: scripts/test-replicate-day.sh   (MARKET_RECORDER as in replicate-day.sh)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/rclone" <<'FAKE'
#!/usr/bin/env bash
# rclone copy SRC DST [flags]: copy the whole tree, ignoring filters.
set -euo pipefail
[[ $1 == copy ]] || exit 1
mkdir -p "$3"
cp -R "$2/." "$3/"
FAKE
chmod +x "$tmp/rclone"

day=2026/10/12
for side in a b; do
  mkdir -p "$tmp/$side/raw/binance/trades/BTCUSDT/$day"
done
printf '%s\n' \
  '2026-10-12T13:35:01.000000Z t1' '' '2026-10-12T13:35:40.000000Z t4' \
  >"$tmp/a/raw/binance/trades/BTCUSDT/$day/13-35.ndjson"
printf '%s\n' \
  '2026-10-12T13:35:01.000200Z t1' '2026-10-12T13:35:10.000000Z t2' \
  '2026-10-12T13:35:40.000100Z t4' \
  >"$tmp/b/raw/binance/trades/BTCUSDT/$day/13-35.ndjson"

RCLONE=$tmp/rclone WORK=$tmp/work DEST=$tmp/dest \
  "$here/replicate-day.sh" "$tmp/a" "$tmp/b" 2026-10-12

merged=$(zstd -dc "$tmp/dest/raw/binance/trades/BTCUSDT/$day/13-35.ndjson.zst")
expected=$'2026-10-12T13:35:01.000000Z t1\n2026-10-12T13:35:10.000000Z t2\n2026-10-12T13:35:40.000000Z t4'
if [[ $merged != "$expected" ]]; then
  echo "unexpected merged minute:" >&2
  echo "$merged" >&2
  exit 1
fi
grep -q '"both": 2' "$tmp/dest/_merge/2026-10-12.json"
grep -q '"gaps_closed": 1' "$tmp/dest/_merge/2026-10-12.json"
if [[ -e $tmp/work/a || -e $tmp/work/b ]]; then
  echo "inputs not removed" >&2
  exit 1
fi
echo "replicate-day ok"
