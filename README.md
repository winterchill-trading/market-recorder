# market-recorder

Raw-first market data recorder for Hyperliquid, Binance USD-M, Bybit linear, OKX,
Coinbase, Kraken, Deribit and Bitget, built on the venues' live feeds (see
[Venues](#venues)).

Every websocket frame is written exactly as received, with its receive timestamp, into
Tardis-style minute files that are compressed with zstd and handed to an upload command
when the minute is over. Next to the raw files the normalized events are appended to the
daily `Market_data.Event_log` files that the `market-data` tools read.

```
market-recorder run -config recorder.sexp [-collector ID]
market-recorder check-config -config recorder.sexp
market-recorder status -url http://localhost:9100     # /metrics of a running recorder as tables
market-recorder rebuild-norm -data-dir DIR -out DIR -date YYYY-MM-DD   # norm/ from raw/
market-recorder merge -a DIR_A -b DIR_B -out DIR -date YYYY-MM-DD      # two collectors into one raw/
```

`-collector ID` (1 to 32 of `A-Za-z0-9_`) adds the id to every raw minute file name,
`<HH>-<MM>.<ID>.ndjson[.zst]`, so two collectors of one venue never write the same
object; `merge -collector-a/-collector-b` and `rebuild-norm -collector` read such files.
At startup the recorder logs its `RLIMIT_NOFILE` (soft and hard).

`MEMTRACE=FILE.ctf` starts [memtrace](https://github.com/janestreet/memtrace) before
anything else runs (`Memtrace.trace_if_requested`), sampling at `MEMTRACE_RATE`
(default 1e-6); an empty or unset `MEMTRACE` does nothing. The infra compose stack and
Helm chart pass both variables through. A build without the `memtrace` library (it is a
declared dependency; dune falls back only when it is missing from the switch) prints a
warning and ignores `MEMTRACE`. CI checks that `MEMTRACE=/tmp/x.ctf market-recorder
-help` writes the trace.

`SIGTERM` or `SIGINT` flushes everything, closes the feeds, writes a disconnect line to
every stream that received data, compresses the open minutes, gives pending uploads up to
10s and exits 0.

## Layout

```
<data_dir>/
  raw/<venue>/<stream>/<symbol>/<YYYY>/<MM>/<DD>/<HH>-<MM>.ndjson      the open minute
  raw/<venue>/<stream>/<symbol>/<YYYY>/<MM>/<DD>/<HH>-<MM>.ndjson.zst  closed minutes
  <venue>/<symbol>/norm/<stream>/<YYYY-MM-DD>.bin                      normalized events
  <venue>/<symbol>/norm/l2/_snapshots/<YYYY-MM-DD>.bin                 full L2 book each minute
  upload-pending.sexp                                                  files not yet uploaded
```

Venues are `hyperliquid`, `binance`, `bybit`, `okx`, `coinbase`, `kraken`, `deribit`,
`bitget`; streams `trades`, `bbo`, `l2`, `funding`. Characters `/`, `\\` and space in a
symbol become `_` in raw paths (`BTC/USD` is `BTC_USD`).
Minutes and days are UTC, taken from the receive time.

- Buffered lines go to the OS every 250ms (and when a buffer passes 1 MiB); event logs use
  the same interval.
- A minute is closed when a frame of a later minute arrives or when the 250ms tick sees
  the wall clock past it, so idle streams are closed on time too.
- On startup any `.ndjson` left by a crash is compressed and queued for upload before
  recording starts. If the `.zst` of that minute already exists (a restart within the
  same minute), the new zstd frame is appended; `zstd -d` reads concatenated frames as
  one stream.
- Receive times never go backwards within a stream: a frame stamped earlier than the
  previous frame of its venue/stream/symbol (the wall clock stepped back) gets the
  previous time, and is counted in `market_recorder_clamped_frames_total`.
- A minute file that cannot be opened, written or compressed (disk full, permissions)
  does not stop the recorder: its lines are dropped, the failure shows on `/healthz` and
  is logged.
- Repeated warnings of one stream (raw writer failures, clamped receive times) are logged
  at most once a minute, with the number suppressed since the last line.
- One live feed is opened per venue entry and symbol, so every frame is known to belong
  to one symbol. Subscription acks and pongs that the client passes to `on_raw` are
  recorded too, as Tardis does.

## Venues

| Venue | Feed library | Streams | Symbol convention | Endpoints |
| --- | --- | --- | --- | --- |
| `Hyperliquid` | `hl-client` | trades, bbo, l2, funding | coin: `BTC`, `ETH` | Mainnet, Testnet, Local (no funding on the simulator), Custom |
| `Binance` | `binance-client` | trades, bbo, l2, funding | USD-M perpetual: `BTCUSDT` | Mainnet, Testnet, Local, Custom |
| `Bybit` | `bybit-client` | trades, bbo, l2, funding | linear perpetual: `BTCUSDT` | Mainnet, Testnet, Local, Custom |
| `Okx` | `okx-feed` | trades, bbo, l2, funding (`-SWAP` only) | instrument id: `BTC-USDT-SWAP`, spot `BTC-USDT` | Mainnet, Testnet (demo trading), Custom |
| `Coinbase` | `coinbase-feed` | trades, bbo, l2 (spot, no funding) | product id: `BTC-USD` | Mainnet, Custom |
| `Kraken` | `kraken-feed` | trades, bbo, l2 (spot v2), funding (futures) | `BTC/USD` or `PF_XBTUSD`; each stream maps it to its API | Mainnet, Custom (+ `futures_ws_url`) |
| `Deribit` | `deribit-feed` | trades, bbo, l2, funding (`-PERPETUAL` only) | instrument name: `BTC-PERPETUAL`, `ETH-PERPETUAL` | Mainnet, Testnet, Custom |
| `Bitget` | `bitget-feed` | trades, bbo, l2, funding | USDT futures: `BTCUSDT` | Mainnet, Custom |

`check-config` rejects a stream the venue cannot deliver for the given symbol or
endpoint (it would hold `/healthz` at 503 forever), an endpoint the venue does not have,
and the venues that have no live feed (`Nyse`, `Cboe`, `Cme`); it prints the errors and
exits 1, as `run` does before connecting anything:

```
$ market-recorder check-config -config bad.sexp
(bad.sexp
 ("invalid config"
  (errors
   ("coinbase: Funding is not available (spot only, no funding channel)"
    "okx: Funding needs perpetual swaps (symbols ending in -SWAP), not BTC-USDT"))))
```

Size units follow the venue: OKX swaps are in contracts, Deribit perpetuals in USD
notional, the others in base currency.

## Configuration

```
((data_dir /var/lib/market-recorder)
 (http_port 9100)                                  ; default 9100
 (venues
  (((venue Binance)                                ; see Venues
    (symbols (BTCUSDT ETHUSDT))                    ; venue names (BTC on Hyperliquid)
    (streams (Trades Bbo L2 Funding))
    (config Mainnet))                              ; default Mainnet
   ((venue Hyperliquid) (symbols (BTC ETH)) (streams (Trades L2 Funding)) (config Testnet))
   ((venue Bybit) (symbols (BTCUSDT)) (streams (Trades L2))
    (config (Custom (base_url https://api.bybit.com) (ws_url wss://stream.bybit.com/v5/public/linear))))))
 (snapshot_interval 1m)                            ; default 1m, 0s turns it off
 (upload                                           ; optional
  ((command (rclone copyto {file} remote:bucket/{rel}))
   (delete_after_upload true))))                   ; default false
```

| Field | Meaning |
| --- | --- |
| `data_dir` | root of the raw and normalized files |
| `http_port` | port of `/healthz` and `/metrics` |
| `venues[].config` | `Mainnet`, `Testnet`, `(Local)` / `(Local (port N))` for a simulator on localhost (default ports 3000, 3300, 3400), or `(Custom (base_url URL) [(ws_url URL)] [(futures_ws_url URL)])`; the websocket-only feeds (OKX, Coinbase, Kraken, Deribit, Bitget) connect to `ws_url`, else `base_url`; `futures_ws_url` is Kraken's funding socket |
| `venues[].streams` | any of `Trades Bbo L2 Funding`; `Private` is rejected |
| `snapshot_interval` | the full L2 book of every instrument is written to its `Snapshot_index` file (market-data) when an L2 update crosses this interval, so a replay can start from the last snapshot instead of the day's first frame; `0s` writes none |
| `upload.command` | program and arguments; `{file}` becomes the absolute path of the closed `.zst`, `{rel}` its path relative to `data_dir` |
| `upload.delete_after_upload` | remove the local file after the command succeeds |

Uploads run at most 4 at a time. A failing command is retried with a backoff from 1s
doubling to 5 min. The pending list is rewritten on every change, so files queued at
shutdown are uploaded by the next run. Normalized event logs are not uploaded.

## Monitoring

- `GET /healthz`: `200 ok` when every configured venue/stream/symbol delivered a frame
  in the last 30s and the raw writer has not failed in that time, else `503` with the
  stale streams as a sexp. The last raw writer failure and its age follow on their own
  line whenever there was one:
  `(last_flush_error ((error "...No space left on device...") (age 5s)))`.
- `GET /metrics`: Prometheus text format.
- `GET /status`: a sexp of the open minute files, the pending uploads (both relative to
  `data_dir`), every stream's counters and each venue client's frames, parse errors and
  reconnects (`clients`).

`market-recorder status -url URL` (default `http://localhost:9100`) fetches `/metrics`
and prints it as one row per stream plus the process gauges:

```
venue        stream   symbol   frames   bytes  events  clamped_frames  norm_pipe_length  healthz_flaps  last_frame_age_seconds
binance      bbo      BTCUSDT      82   13633      81               0                 0              0                   0.091
bybit        trades   BTCUSDT      38   11144      70               0                 0              0                   0.070
hyperliquid  l2       BTC         182  270819     182               0                 0              0                   0.037
...

client_frames{venue=hyperliquid}            920
client_frames{venue=binance}                1435
client_frames{venue=bybit}                  1963
parse_errors{venue=hyperliquid}             0
parse_errors{venue=binance}                 0
parse_errors{venue=bybit}                   0
reconnects{venue=hyperliquid}               0
reconnects{venue=binance}                   0
reconnects{venue=bybit}                     0
uploads                                     0
upload_failures                             0
upload_pending                              0
build_info{version=unknown,ocaml=5.2.0+ox}  1
open_fds                                    72
gc_minor_collections                        8
gc_major_collections                        4
gc_compactions                              0
gc_heap_words                               1181337
gc_top_heap_words                           410953
```

| Metric | Labels | |
| --- | --- | --- |
| `market_recorder_frames_total` | venue, stream, symbol | raw frames |
| `market_recorder_bytes_total` | venue, stream, symbol | raw frame bytes |
| `market_recorder_events_total` | venue, stream, symbol | normalized events |
| `market_recorder_clamped_frames_total` | venue, stream, symbol | frames whose receive time was raised to the previous one |
| `market_recorder_gaps_total` | venue, stream, symbol | gaps the venue client reported (reconnects, book resyncs) |
| `market_recorder_norm_pipe_length` | venue, stream, symbol | normalized events waiting for the event log writer |
| `market_recorder_healthz_flaps_total` | venue, stream, symbol | times the stream went stale after being fresh (seen by `/healthz` or `/metrics` requests) |
| `market_recorder_last_frame_age_seconds` | venue, stream, symbol | since the last frame (since start if none) |
| `market_recorder_client_frames_total` | venue | websocket text frames the venue clients received, acks and heartbeats included, summed over the venue's feeds |
| `market_recorder_parse_errors_total` | venue | frames the clients dropped as undecodable, plus error responses from the server |
| `market_recorder_reconnects_total` | venue | successful reconnections (the first connection excluded) |
| `market_recorder_exchange_lag_seconds` | venue | `recv_ts - exch_ts` of the venue's latest trade, BBO or L2 event (funding left out) |
| `market_recorder_clock_error_seconds` | | clock error bound from `chronyc -c tracking`, every 30 s: \|offset\| + root delay / 2 + root dispersion; absent without chrony |
| `market_recorder_long_cycles_total` | | Async cycles over 50 ms (each cycle over 20 ms is logged, at most once per 10 s with a suppressed count) |
| `market_recorder_longest_cycle_seconds` | | longest Async cycle over 20 ms since start |
| `market_recorder_uploads_total` | | files uploaded |
| `market_recorder_upload_failures_total` | | failed command runs |
| `market_recorder_upload_pending` | | files waiting |
| `market_recorder_build_info` | version, ocaml | always 1; `version` is `git describe` at build time (`unknown` outside a checkout) |
| `market_recorder_open_fds` | | open file descriptors (`/proc/self/fd` or `/dev/fd`) |
| `market_recorder_max_fds` | | soft `RLIMIT_NOFILE` |
| `market_recorder_resident_memory_bytes` | | resident set size (Linux only) |
| `market_recorder_gc_minor_collections_total`, `_gc_major_collections_total`, `_gc_compactions_total` | | GC counters |
| `market_recorder_gc_heap_words`, `_gc_top_heap_words` | | major heap size, current and peak |

The per-stream families count frames as passed to the raw writer; the per-venue client
families come from each client's own `stats` (one reader per feed, summed per venue).
The status endpoint carries the same client counters under `clients`. Hyperliquid
`l2Book` frames feed both `l2` and `bbo` but are written once, under `l2` when it is
recorded; `bbo` then only has the event columns (`-` in `market-recorder status`) and is
left out of the health rule.

Every venue's client reports each reconnect and book resync as a `Market_data.Gap.t` on
its `feed_with_gaps`; the recorder counts it per stream and writes a disconnect line into
each affected stream's open raw minute file, so a mid-run reconnect shows in the raw files
the way a shutdown does. A gap with an instrument (a book resync) only marks that symbol's
files; a gap without one (a reconnect) marks every symbol of the connection. None of the
venues replays missed messages, so the window between the drop and the resubscription
(0.4 to 0.6 s of backoff on a first reconnect, plus the handshake) is lost:

| Venue | Gaps reported | What a reconnect loses |
| --- | --- | --- |
| Hyperliquid | reconnects (no stream or instrument) | trades in the window; books and bbo recover from the fresh `l2Book` snapshot |
| Binance | reconnects per stream, diff-depth sequence breaks per symbol | trades in the window; the book resyncs from a REST snapshot |
| Bybit | reconnects per stream, book sequence breaks per symbol | trades in the window; the book restarts from the snapshot sent on subscribe |
| OKX | reconnects per stream, L2 sequence breaks per symbol | trades for good (no history on subscribe); the book restarts from the `books` snapshot |
| Coinbase | reconnects per stream, `level2` sequence breaks for every synced product | `level2` deltas and quotes in the window; trades only beyond the backlog resent on subscribe |
| Kraken | reconnects per stream, book checksum mismatches per symbol | trades in the window (no backfill); the book restarts from a new snapshot |
| Deribit | reconnects per stream, book `change_id` breaks per symbol | trades and quotes in the window; the book restarts from a full snapshot |
| Bitget | reconnects per stream, `books` sequence or checksum breaks per symbol | trades beyond the last 50 resent on subscribe; the book restarts from the snapshot |

`test/test_gaps.ml` drives `Recorder.record_gaps` with a stand-in gaps pipe: a
reconnect marks every open file, and a per-instrument L2 gap marks only that symbol's
L2 file.

A stalled event log (a disk that stops taking writes) does not push back on the feeds:
`Norm_writer` drains the feed pipes and the events wait in the writer's memory, so
`norm_pipe_length` stays at zero while the files stop growing
(`test_norm_writer.ml` shows 10000 events buffered, nothing flushed).

[`deploy/prometheus/alerts.yml`](deploy/prometheus/alerts.yml) is an example rule file:
`MarketRecorderParseErrors` fires when a venue's parse error rate stays above zero for
5 minutes (usually a venue changed its message format), `MarketRecorderReconnecting` on
more than 3 reconnects in 15 minutes. CI checks it with `promtool check rules` and runs
the unit test in `deploy/prometheus/alerts_test.yml` (`promtool test rules`).

## Rebuilding norm from raw

The raw minute files are the system of record; the event logs can be rebuilt from them
at any time, for example after a normalizer fix:

```
market-recorder rebuild-norm -data-dir DIR -out NEW_DIR -date 2026-10-12 \
  [-venue binance ...] [-skip venue:stream ...] [-collector ID]
scripts/rebuild-day.sh DIR [2026-10-12] [flags...]   # default: yesterday, into DIR/rebuilt/DATE
```

It runs `Market_data.Rebuild_norm` with the `Market_data.Normalizer.S` adapter of every
venue the recorder records (`Rebuild.normalizers`: Hyperliquid, Binance, Bybit, OKX,
Coinbase, Kraken, Deribit, Bitget). Each raw venue/stream/symbol series gets a fresh
normalizer, fed its minute files in order; a disconnect line resets it as a reconnect
does. The output has the recorder's `norm/` layout, so a rebuilt directory can replace or
be diffed against the live one. The output directory must be new or empty (event logs are
appended to).

- `-venue V` (repeatable) rebuilds only those venues; the others count as skipped.
- `-skip venue:stream` (repeatable) leaves a raw stream out entirely, for streams with
  data known not to rebuild. The rebuild then reads a temporary directory of symlinks to
  the other `raw/<venue>/<stream>` directories, removed afterwards. Hyperliquid's `bbo`
  events come from the `l2` frames, so `-skip hyperliquid:l2` drops both.
- `-collector ID` reads that collector's files (`<HH>-<MM>.<ID>.ndjson.zst`) through a
  temporary directory of per-file symlinks under their plain names; without it, files
  with a collector id are ignored.
- The L2 snapshot index (`norm/l2/_snapshots/`) is not written: `Rebuild_norm` takes no
  snapshot interval.

`scripts/e2e-rebuild.sh [seconds] [-skip venue:stream ...]` records the three simulators
with `e2e-sims.sh`, rebuilds the day into `/tmp/market-recorder-sims/rebuilt/<date>` and
compares every recorded event log with its rebuilt copy (event count via
`market-data dump`, then `cmp`). A 20 s run (two symbols on each of Hyperliquid, Binance
and Bybit, 40 minute files, 2236 frames, 2545 events) rebuilt all 22 event logs byte for
byte identical, with no rejected frames; the only files not reproduced are the 6 L2
snapshot index files.

## Merging two collectors

Two recorders on the same venues, symbols and streams (two collectors, ideally in two
regions) each write their own raw minute files. `merge` turns a day of both into one
canonical copy in the same layout, so every reader (rebuild-norm, day close, replay)
works on it unchanged:

```
market-recorder merge -a A_DATA_DIR -b B_DATA_DIR -out NEW_DIR -date 2026-10-12 \
  [-window 5s] [-clock-error 2ms] [-silence 10s] [-collector-a ID] [-collector-b ID]
scripts/replicate-day.sh REMOTE_A REMOTE_B [2026-10-12] [merge flags...]
```

Per venue, stream, symbol and minute (`Raw_merge.merge_minute`):

- Frames are matched by their identity: the venue sequence number where the stream has
  one (`Venue_seq`: Binance `depthUpdate` `u`, Binance `aggTrade` `a`, Bybit book
  message type and `u`), else the frame text. A frame of copy A and one of copy B with
  the same identity and `recv_ts` at most `-window` apart (default 5 s) are one venue
  message, written once with the earlier `recv_ts`; pairs whose texts differ are counted
  (`text_differs`). Repeated identical frames pair up in time order. Unmatched frames
  in the last window of a minute are also matched against the next minute of the other
  copy, so a message stamped 13:35:59.999 on one side and 13:36:00.001 on the other is
  kept once; the day's first minute is matched against the previous day's 23:59 files
  the same way (`previous_day` counts the frames dropped for it).
- `-clock-error SPAN` is the two collectors' summed clock error bound (for example the
  sum of both `market_recorder_clock_error_seconds`): it widens the window, and when two
  copies' stamps are closer than it, copy A's is kept, since the clocks cannot say which
  came first.
- A disconnect line covers the span from the previous frame of its file (or the start of
  the minute) to the next frame (or the end of the minute). It is written only when the
  other copy also has a gap overlapping that span (its own disconnect, or no file for the
  minute); otherwise the other copy filled it and the line is dropped. Two overlapping
  disconnects are written once.
- Lines are ordered by `recv_ts`, copy A first on ties; the output is compressed by the
  recorder's own `Raw_writer`. The output directory must not hold raw files of that day.

`<out>/_merge/<date>.json` reports per series and in total: `minutes` written, `only_a`
and `only_b` (frames one copy missed), `both`, `gaps_closed` (disconnect lines the peer
filled), `gaps_kept` (gaps both copies had), `text_differs` and `previous_day`. The
command prints the totals. Each series also reports:

- `median_interval_ms` and `suspected_gaps`: stretches longer than `-silence` (default
  10 s) without a merged frame, including from midnight to the first frame and from the
  last frame to the end of the day, on streams that normally tick (median interval at
  most a tenth of `-silence`, from a power-of-two histogram, so a quiet trade stream
  reports none).
- For streams with a venue sequence: `seq_gaps`, the exact ranges of sequence numbers
  missing from the merged output (`first_missing`, `last_missing`, `at` = the
  `recv_ts` of the message after the gap), and `seq_gaps_a` / `seq_gaps_b`, the number
  of gaps each copy had on its own (filled where the other copy had the messages).
  Binance depth gaps are `pu` not equal to the previous `u`; aggregate trades and Bybit
  book deltas must continue by one; a Bybit snapshot with `u = 1` restarts the sequence.
  Checks pass through a reorder buffer of `-window` plus `-clock-error`, since the two
  copies interleave slightly out of order.

`-collector-a ID` / `-collector-b ID` read only that collector's files
(`<HH>-<MM>.<ID>.ndjson.zst`); `-a` and `-b` may then be the same tree, as after
cross-region replication into one bucket. Without them, only files without an id are
read. The merged output always uses plain names.

Not yet implemented from [the replication design][replication]: ordering frames inside
the clock bound by venue sequence (they keep `recv_ts` order), and the L2 snapshot rule
after a fill.

`scripts/replicate-day.sh` fetches one day of both collectors' `raw/` trees with
`rclone copy --include '/raw/*/*/*/YYYY/MM/DD/**'` into `$WORK/a` and `$WORK/b` (default
`./replicate/DATE`), merges into `$WORK/out`, copies that to `$DEST` when set, and
removes the inputs unless `KEEP_INPUT=1`. `REMOTE_A` and `REMOTE_B` are the uploaders'
destinations without `{rel}`. `$RCLONE` replaces the rclone binary;
`scripts/test-replicate-day.sh` (run in CI) uses a stand-in that copies local trees.

What infra needs to run it (not done here):

- Each collector uploads under its own prefix or bucket
  (`rclone copyto {file} s3:bucket/<collector>/{rel}`), so the two copies never share a
  key.
- A daily job per venue group, after cross-region replication has delivered the day:
  `replicate-day.sh s3:bucket/a s3:bucket/b DATE` with `DEST` set to the canonical
  prefix, then the day close over the merged `raw/` with `-force`.
- The image needs rclone (already there) and enough scratch space for two copies and
  the output of one day.

[replication]: https://github.com/winterchill-trading/specs/blob/main/design/cloud-sinks-and-replication.md

## Tardis compatibility

The raw line format matches the tardis.dev raw data feeds: the local (receive) timestamp
in ISO 8601 UTC, a space, then the exchange-native message unchanged, one message per
line; an empty line marks a disconnect. Timestamps carry microseconds
(`2026-10-12T11:55:46.082768Z`). Tardis groups raw data by exchange and day with all
channels mixed; here files are split per stream, symbol and minute, so a Tardis-style
day file of one stream is the concatenation of its minute files in name order
(`zstd -dc .../12/*.ndjson.zst`). Frames containing newlines (none of the venues sends
any) would have them replaced by spaces.

## End to end against the simulators

`scripts/e2e-sims.sh [seconds]` builds and starts `hl-sim -port 3510`,
`binance-sim -port 3520` and `bybit-sim -port 3530`, records them with
[`examples/sims.sexp`](examples/sims.sexp) (two symbols per venue, upload command copying
to `/tmp/market-recorder-sims/remote`), queries `/healthz`, `/status` and `/metrics`
(through `market-recorder status`), sends `SIGTERM`, lists the files and decompresses a
few, then kills the simulators. It exits 1, listing every `PROBLEM`, when `/healthz` is
not 200 or reports a raw writer failure, a stream received no frame, an upload failed or
is still pending, a venue client counted parse errors, the recorder exits non-zero, or a
stream lacks a compressed minute, its uploaded copy or its event log. Run it from this repo inside the multi-repo dune
workspace, or point `WORKSPACE` at another workspace root holding the simulators
(`OPAM_SWITCH` names the switch, `5.2.0+ox` by default). CI runs it for 20 s in the
`e2e-sims` job, in a workspace of this repository and the three simulators checked out
from `main`, and keeps the logs as an artifact:

```
DUNE_BUILD_DIR=../_build-market-recorder scripts/e2e-sims.sh 75
```

CI runs `shellcheck` on `scripts/*.sh`.

The same by hand:

```
hl-sim -port 3510 & binance-sim -port 3520 & bybit-sim -port 3530 &
market-recorder run -config examples/sims.sexp 2>recorder.log &
curl -s localhost:9910/healthz
curl -s localhost:9910/metrics
kill -TERM %4
zstd -dc /tmp/market-recorder-sims/data/raw/binance/bbo/BTCUSDT/2026/10/12/11-56.ndjson.zst | head -2
```

Sample output of a 75s run (excerpts):

```
== /healthz
ok
200
== /metrics
market_recorder_frames_total{venue="hyperliquid",stream="l2",symbol="BTC"} 701
market_recorder_frames_total{venue="binance",stream="trades",symbol="BTCUSDT"} 292
market_recorder_frames_total{venue="binance",stream="l2",symbol="BTCUSDT"} 701
market_recorder_frames_total{venue="bybit",stream="funding",symbol="BTCUSDT"} 712
market_recorder_bytes_total{venue="binance",stream="l2",symbol="BTCUSDT"} 184501
market_recorder_events_total{venue="binance",stream="l2",symbol="BTCUSDT"} 699
market_recorder_last_frame_age_seconds{venue="binance",stream="funding",symbol="BTCUSDT"} 0.626
market_recorder_uploads_total 44
market_recorder_upload_failures_total 0
market_recorder_upload_pending 0
== recorder exit 0
== files
./binance/BTCUSDT/norm/l2/2026-10-12.bin
./raw/binance/bbo/BTCUSDT/2026/10/12/11-55.ndjson.zst
./raw/binance/bbo/BTCUSDT/2026/10/12/11-56.ndjson.zst
./raw/binance/bbo/BTCUSDT/2026/10/12/11-57.ndjson.zst
...
== zstd -dc raw/binance/bbo/BTCUSDT/2026/10/12/11-56.ndjson.zst | head -2
2026-10-12T11:56:00.084611Z {"stream":"btcusdt@bookTicker","data":{"e":"bookTicker","u":935,"E":1791806160083,"T":1791806160083,"s":"BTCUSDT","b":"100146.4","B":"0.072","a":"100188","A":"0.013"}}
2026-10-12T11:56:00.191674Z {"stream":"btcusdt@bookTicker","data":{"e":"bookTicker","u":944,"E":1791806160191,"T":1791806160191,"s":"BTCUSDT","b":"100146.4","B":"0.07","a":"100188","A":"0.013"}}
```

The first line of a stream's first minute is the venue's subscription ack, e.g.
`2026-10-12T11:55:45.987140Z {"result":null,"id":3}` on Binance, and the last line of the
last minute is the empty disconnect line written at shutdown. The Hyperliquid simulator
does not serve `activeAssetCtx`, so the example config records no Hyperliquid funding
(a stream that never delivers would keep `/healthz` at 503).

## End to end against the real venues

`scripts/e2e-mainnet.sh [seconds]` records the eight venues on mainnet with
[`examples/mainnet-all.sexp`](examples/mainnet-all.sexp) (one BTC market per venue, the
perpetual where there is one; upload command copying to
`/tmp/market-recorder-mainnet/remote`), queries `/healthz` and `/metrics` on port 9920,
sends `SIGTERM` and lists the files. It needs network access:

```
DUNE_BUILD_DIR=../_build-market-recorder scripts/e2e-mainnet.sh 90
```

Feeds are opened one after another, so the first frames of the last venue arrive about
20s after start (here 13:34:44 to 13:35:05 UTC). Excerpts of a 90s run on 2026-10-12:

```
== /healthz
ok
200
== /metrics
market_recorder_frames_total{venue="hyperliquid",stream="funding",symbol="BTC"} 87
market_recorder_frames_total{venue="binance",stream="bbo",symbol="BTCUSDT"} 93530
market_recorder_frames_total{venue="bybit",stream="l2",symbol="BTCUSDT"} 3789
market_recorder_frames_total{venue="okx",stream="trades",symbol="BTC-USDT-SWAP"} 3200
market_recorder_frames_total{venue="okx",stream="funding",symbol="BTC-USDT-SWAP"} 840
market_recorder_frames_total{venue="coinbase",stream="l2",symbol="BTC-USD"} 1155
market_recorder_frames_total{venue="kraken",stream="l2",symbol="PF_XBTUSD"} 7060
market_recorder_frames_total{venue="kraken",stream="funding",symbol="PF_XBTUSD"} 255
market_recorder_frames_total{venue="deribit",stream="bbo",symbol="BTC-PERPETUAL"} 1338
market_recorder_frames_total{venue="deribit",stream="funding",symbol="BTC-PERPETUAL"} 209
market_recorder_frames_total{venue="bitget",stream="trades",symbol="BTCUSDT"} 843
market_recorder_frames_total{venue="bitget",stream="l2",symbol="BTCUSDT"} 706
market_recorder_bytes_total{venue="coinbase",stream="l2",symbol="BTC-USD"} 10046925
market_recorder_events_total{venue="okx",stream="funding",symbol="BTC-USDT-SWAP"} 695
market_recorder_events_total{venue="kraken",stream="trades",symbol="PF_XBTUSD"} 268
market_recorder_events_total{venue="deribit",stream="trades",symbol="BTC-PERPETUAL"} 988
market_recorder_last_frame_age_seconds{venue="okx",stream="funding",symbol="BTC-USDT-SWAP"} 0.126
market_recorder_last_frame_age_seconds{venue="coinbase",stream="trades",symbol="BTC-USD"} 0.306
market_recorder_last_frame_age_seconds{venue="kraken",stream="funding",symbol="PF_XBTUSD"} 0.011
market_recorder_last_frame_age_seconds{venue="deribit",stream="trades",symbol="BTC-PERPETUAL"} 0.733
market_recorder_last_frame_age_seconds{venue="bitget",stream="bbo",symbol="BTCUSDT"} 0.067
market_recorder_uploads_total 57
market_recorder_upload_failures_total 0
market_recorder_upload_pending 0
== recorder exit 0
== files
./coinbase/BTC-USD/norm/l2/2026-10-12.bin
./kraken/BTC_USD/norm/l2/2026-10-12.bin
./kraken/PF_XBTUSD/norm/funding/2026-10-12.bin
./okx/BTC-USDT-SWAP/norm/funding/2026-10-12.bin
./raw/bitget/l2/BTCUSDT/2026/10/12/13-35.ndjson.zst
./raw/bitget/l2/BTCUSDT/2026/10/12/13-36.ndjson.zst
./raw/coinbase/trades/BTC-USD/2026/10/12/13-34.ndjson.zst
./raw/deribit/funding/BTC-PERPETUAL/2026/10/12/13-35.ndjson.zst
./raw/deribit/l2/BTC-PERPETUAL/2026/10/12/13-36.ndjson.zst
./raw/kraken/funding/PF_XBTUSD/2026/10/12/13-35.ndjson.zst
./raw/okx/trades/BTC-USDT-SWAP/2026/10/12/13-34.ndjson.zst
...
```

All 31 venue/stream pairs had a frame in the last second; every venue produced minute
files (8 to 12 per venue over three minutes, 88 in all), each copied to the remote
directory. The first OKX trades line is its subscription ack:
`2026-10-12T13:34:50.358325Z {"event":"subscribe","arg":{"channel":"trades","instId":"BTC-USDT-SWAP"},"connId":"7a4bb6b7"}`.

Raw files are kept under the configured symbol, but normalized events carry the symbol
the venue sends: Kraken's spot streams for `PF_XBTUSD` come from `BTC/USD`, which the
event log stores under `kraken/BTC_USD/` (market-data maps `/` to `_` in paths), while
its funding stays under `kraken/PF_XBTUSD/`.

## Throughput

`bench/bench.exe [-per-second N]` builds one synthetic minute of Binance `BTCUSDT`
frames (30% `aggTrade`, the rest `bookTicker`, a `markPrice` every 1000 frames, about
170 bytes each), runs it through the Binance feed normalizer, the raw minute writer
(including the zstd roll on close) and the event log writer, and prints each stage's
rate. It then times the recorder's per-frame path alone (`Recorder.Frame_sink.on_raw`:
clamp, counters, raw line into an open minute file) and counts its minor words. On an
M-series Mac, release profile, single core:

```
one minute at 2000 frames/s: 120000 frames, 20.7 MB raw, 120000 events, 0.9 MB compressed
  normalize         2264023 frames/s    390.8 MB/s  (53ms)
  raw write + zstd  1059949 frames/s    182.9 MB/s  (113.2ms)
  event log write   5923878 frames/s   1022.5 MB/s  (20.3ms)
  all three          643525 frames/s    111.1 MB/s  (186.5ms)
  on_raw            2475654 frames/s    427.3 MB/s  (48.5ms)  0.0 words/frame
```

So one core handles about 600k frames/s (110 MB/s) end to end, up from about 250k
before the normalizer's scanner and the per-frame changes below. The busiest mainnet
stream in the 90s run above (Binance `BTCUSDT` bbo, about 1000 frames/s) uses under 0.2%
of that.

### Per-frame path

`on_raw` used to build a `Metrics.Key` per frame and hash it three times (clamp, the
seen set, the counters), store `last_frame` as an option, format the timestamp with
`sprintf`, join the line with `String.concat` and hash a second key to find the minute
file. Now `Frame_sink` resolves each stream's counters (`Metrics.Handle`) and minute
file slot (`Raw_writer.Handle`) on the stream's first frame, `last_frame` is
`Time_ns.t or_null`, and the line is written straight into the file's buffer with the
timestamp from a reused buffer whose `YYYY-MM-DDTHH:MM:` prefix changes once a minute.
Best of five alternating runs, same machine and siblings, before and after:

| Stage | Build | Before | After |
| --- | --- | ---: | ---: |
| `on_raw` | dev | 832 ns, 186.5 words | 383 ns, 0 words |
| `on_raw` | release | 795 ns, 186.5 words | 380 ns, 0 words |
| `on_raw` | release `-O3` | 843 ns, 182.5 words | 378 ns, 0 words |
| raw write + zstd | release | 1307 ns | 902 ns |
| all three stages | release | 1879 ns | 1508 ns |

Words are exact and pinned in `test/test_frame_sink.ml` and `test/test_raw_line.ml`
(measured on arm64; CI runs amd64). What remains is copying the line into the file's
buffer and that buffer's growth. `test/test_raw_line.ml` checks the written files
against the old `sprintf` and `String.concat` builder over random times (before the
epoch included) and frames with newlines.

The same bench then merges two copies of the minute (copy B 300 us later, each missing a
different 1% of the frames), in memory and from compressed files to compressed files:

```
merge of two copies: 237600 lines in, 1200 only_a, 1200 only_b, 117600 both
  merge in memory   1463703 frames/s    255.2 MB/s  (162.3ms)
  merge files        421721 frames/s     73.5 MB/s  (563.4ms)
merge of two copies: 1188000 lines in, 6000 only_a, 6000 only_b, 588000 both   (10000/s)
  merge in memory    924538 frames/s    162.2 MB/s  (1.3s)
  merge files        356860 frames/s     62.6 MB/s  (3.3s)
```

At about 0.36 to 0.42 M input lines/s, a day of the busiest stream (two copies at
1000 frames/s, 173 M lines) merges in about 8 minutes on one core.

## Modules

| Module | |
| --- | --- |
| `Config` | sexp configuration, endpoint to client config |
| `Raw_writer` | minute files, 250ms flush, zstd roll, crash recovery |
| `Norm_writer` | normalized events into `Market_data.Event_log` |
| `Uploader` | upload command queue with retries and a persistent pending list |
| `Metrics` | counters, clamping of receive times, health rule and flaps, Prometheus rendering |
| `Recorder` | feeds per venue and symbol wired to the writers |
| `Http_server` | `/healthz`, `/metrics` and `/status` on cohttp-async |
| `Warnings` | per-stream warnings, at most one line a minute with a suppressed count |
| `Process_metrics` | build info, open descriptors, RSS and GC gauges |
| `Status_table` | Prometheus text parser and the tables of `status` |
| `Rebuild` | `rebuild-norm` over every venue's normalizer, venue filter and skip list |
| `Raw_merge` | `merge`: two collectors' raw minute files into one canonical copy with a report |
| `Raw_files` | collector ids in raw minute file names; listing one collector's files |
| `Venue_seq` | venue sequence numbers (identity and contiguity checks) read from raw frames |
| `Seq_gaps` | exact sequence gaps with a reorder buffer |
| `Silence` | suspected gaps from silence on streams that normally tick |
| `Clock_error` | clock error bound sampled from `chronyc -c tracking` |
| `Cycle_monitor` | long Async cycles counted and warned about |
