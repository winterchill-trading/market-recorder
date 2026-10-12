# market-recorder

Raw-first market data recorder for Hyperliquid, Binance USD-M and Bybit linear, built on
the venue clients' live feeds (`hl-client`, `binance-client`, `bybit-client`).

Every websocket frame is written exactly as received, with its receive timestamp, into
Tardis-style minute files that are compressed with zstd and handed to an upload command
when the minute is over. Next to the raw files the normalized events are appended to the
daily `Market_data.Event_log` files that the `market-data` tools read.

```
market-recorder run -config recorder.sexp
market-recorder check-config -config recorder.sexp
```

`SIGTERM` or `SIGINT` flushes everything, closes the feeds, writes a disconnect line to
every stream that received data, compresses the open minutes, gives pending uploads up to
10s and exits 0.

## Layout

```
<data_dir>/
  raw/<venue>/<stream>/<symbol>/<YYYY>/<MM>/<DD>/<HH>-<MM>.ndjson      the open minute
  raw/<venue>/<stream>/<symbol>/<YYYY>/<MM>/<DD>/<HH>-<MM>.ndjson.zst  closed minutes
  <venue>/<symbol>/norm/<stream>/<YYYY-MM-DD>.bin                      normalized events
  upload-pending.sexp                                                  files not yet uploaded
```

Venues are `hyperliquid`, `binance`, `bybit`; streams `trades`, `bbo`, `l2`, `funding`.
Minutes and days are UTC, taken from the receive time.

- Buffered lines go to the OS every 250ms (and when a buffer passes 1 MiB); event logs use
  the same interval.
- A minute is closed when a frame of a later minute arrives or when the 250ms tick sees
  the wall clock past it, so idle streams are closed on time too.
- On startup any `.ndjson` left by a crash is compressed and queued for upload before
  recording starts. If the `.zst` of that minute already exists (a restart within the
  same minute), the new zstd frame is appended; `zstd -d` reads concatenated frames as
  one stream.
- One live feed is opened per venue entry and symbol, so every frame is known to belong
  to one symbol. Subscription acks and pongs that the client passes to `on_raw` are
  recorded too, as Tardis does.

## Configuration

```
((data_dir /var/lib/market-recorder)
 (http_port 9100)                                  ; default 9100
 (venues
  (((venue Binance)                                ; Hyperliquid | Binance | Bybit
    (symbols (BTCUSDT ETHUSDT))                    ; venue names (BTC on Hyperliquid)
    (streams (Trades Bbo L2 Funding))
    (config Mainnet))                              ; default Mainnet
   ((venue Hyperliquid) (symbols (BTC ETH)) (streams (Trades L2 Funding)) (config Testnet))
   ((venue Bybit) (symbols (BTCUSDT)) (streams (Trades L2))
    (config (Custom (base_url https://api.bybit.com) (ws_url wss://stream.bybit.com/v5/public/linear))))))
 (upload                                           ; optional
  ((command (rclone copyto {file} remote:bucket/{rel}))
   (delete_after_upload true))))                   ; default false
```

| Field | Meaning |
| --- | --- |
| `data_dir` | root of the raw and normalized files |
| `http_port` | port of `/healthz` and `/metrics` |
| `venues[].config` | `Mainnet`, `Testnet`, `(Local)` / `(Local (port N))` for a simulator on localhost (default ports 3000, 3300, 3400), or `(Custom (base_url URL) [(ws_url URL)])` |
| `venues[].streams` | any of `Trades Bbo L2 Funding`; `Private` is rejected |
| `upload.command` | program and arguments; `{file}` becomes the absolute path of the closed `.zst`, `{rel}` its path relative to `data_dir` |
| `upload.delete_after_upload` | remove the local file after the command succeeds |

Uploads run at most 4 at a time. A failing command is retried with a backoff from 1s
doubling to 5 min. The pending list is rewritten on every change, so files queued at
shutdown are uploaded by the next run. Normalized event logs are not uploaded.

## Monitoring

- `GET /healthz`: `200 ok` when every configured venue/stream/symbol delivered a frame
  in the last 30s, else `503` with the stale streams as a sexp.
- `GET /metrics`: Prometheus text format.

| Metric | Labels | |
| --- | --- | --- |
| `market_recorder_frames_total` | venue, stream, symbol | raw frames |
| `market_recorder_bytes_total` | venue, stream, symbol | raw frame bytes |
| `market_recorder_events_total` | venue, stream, symbol | normalized events |
| `market_recorder_last_frame_age_seconds` | venue, stream, symbol | since the last frame (since start if none) |
| `market_recorder_uploads_total` | | files uploaded |
| `market_recorder_upload_failures_total` | | failed command runs |
| `market_recorder_upload_pending` | | files waiting |

Parse errors and reconnects are handled inside the venue clients (logged, resubscribed)
and are not visible through the `Market_data.Feed.t` interface, so they are not counted
and reconnects do not produce disconnect lines; only shutdown does.

## Tardis compatibility

The raw line format matches the tardis.dev raw data feeds: the local (receive) timestamp
in ISO 8601 UTC, a space, then the exchange-native message unchanged, one message per
line; an empty line marks a disconnect. Timestamps carry microseconds
(`2026-10-12T11:55:46.082768Z`). Tardis groups raw data by exchange and day with all
channels mixed; here files are split per stream, symbol and minute, so a Tardis-style
day file of one stream is the concatenation of its minute files in name order
(`zstd -dc .../12/*.ndjson.zst`). Frames containing newlines (none of the three venues
sends any) would have them replaced by spaces.

## End to end against the simulators

`scripts/e2e-sims.sh [seconds]` builds and starts `hl-sim -port 3510`,
`binance-sim -port 3520` and `bybit-sim -port 3530`, records them with
[`examples/sims.sexp`](examples/sims.sexp) (two symbols per venue, upload command copying
to `/tmp/market-recorder-sims/remote`), queries `/healthz` and `/metrics`, sends
`SIGTERM`, lists the files and decompresses a few, then kills the simulators. Run it from
this repo inside the multi-repo dune workspace:

```
DUNE_BUILD_DIR=../_build-market-recorder scripts/e2e-sims.sh 75
```

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
./kraken/BTC/USD/norm/l2/2026-10-12.bin
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
event log stores under `kraken/BTC/USD/` (one directory level per `/`), while its funding
stays under `kraken/PF_XBTUSD/`.

## Modules

| Module | |
| --- | --- |
| `Config` | sexp configuration, endpoint to client config |
| `Raw_writer` | minute files, 250ms flush, zstd roll, crash recovery |
| `Norm_writer` | normalized events into `Market_data.Event_log` |
| `Uploader` | upload command queue with retries and a persistent pending list |
| `Metrics` | counters, health rule, Prometheus rendering |
| `Recorder` | feeds per venue and symbol wired to the writers |
| `Http_server` | `/healthz` and `/metrics` on cohttp-async |
