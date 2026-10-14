# market-recorder: agent guide

## Purpose

Raw-first recorder for the organization's crypto venues: Hyperliquid, Binance USD-M, Bybit linear,
OKX, Coinbase, Kraken, Deribit and Bitget. Every websocket frame is written exactly as received,
with its receive time, into Tardis-style minute files (zstd-compressed, handed to an upload command
when a minute ends). Normalized events go to `Market_data.Event_log` daily files. The raw files are
the system of record.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | Library `market-recorder` (module `Market_recorder`): config, raw and normalized writers, uploader, metrics, HTTP status, gap and sequence checks, merge, rebuild |
| `bin/` | The `market-recorder` CLI: `run`, `check-config`, `status`, `rebuild-norm`, `merge` |
| `bench/` | Throughput benchmark of the per-frame path |
| `test/` | Expect and integration tests, including a local websocket server and the rotation tests |
| `scripts/` | End-to-end and rebuild scripts, replication script and its test |
| `deploy/` | `prometheus/alerts.yml` and its test |
| `examples/` | `sims.sexp` (the three simulators) and `mainnet-all.sexp` (real venues) |
| `.github/` | CI workflow: build, tests, `e2e-sims` job, alert rules |

## Build, test, docs

Run from this repository, inside the workspace:

    opam exec --switch 5.2.0+ox -- dune build --root .. @market-recorder/all
    opam exec --switch 5.2.0+ox -- dune build --root .. @market-recorder/runtest

Building needs `libsecp256k1-dev`. Several agents building at once need `DUNE_BUILD_DIR=_build-market-recorder`.

Standalone, outside the workspace: add the organization's opam repository
(`opam repo add winterchill https://github.com/winterchill-trading/opam-repository.git`), install
the published dependencies, then run `dune build` here.

## Conventions

- Format this repository only: `dune build --root .. @market-recorder/fmt --auto-promote`. Never
  `dune fmt` at the workspace root.
- Every module has an `.mli`; every public value has an odoc comment.
- Raw files are written exactly as received. Anything that rewrites a frame needs a new format
  decision, recorded in `../specs/adr/`.
- Each new metric is named `market_recorder_*`, carries the venue, stream and symbol labels where it
  applies, .
- Comments for humans at pinned numbers and at workarounds, such as the close-after-first-write fix.

## Dependencies

- Depends on sibling repositories `market-data`, `hl-client`, `binance-client`, `bybit-client`,
  `okx-feed`, `coinbase-feed`, `kraken-feed`, `deribit-feed`, `bitget-feed`, plus zstd and cohttp-async.
- Used by `infra` (service image with rclone, compose service, one Helm Deployment per venue).
- CI pin order is the `pins:` list in `.github/workflows/ci.yml`, in dependency order.

## CI

`ci.yml` runs shellcheck on `scripts/`, installs `libsecp256k1-dev`, runs the ox-setup action with the
pins, then `dune build`, `dune test` and `scripts/test-replicate-day.sh`. The `e2e-sims` job records
the three simulators for 20 seconds (`scripts/e2e-sims.sh 20`). The alert rules job checks
`deploy/prometheus/alerts.yml`. The `obj-magic` job calls the reusable workflow in
`winterchill-trading/infra`. To check a run, use `gh run list --limit 1` and at most one
`gh run watch <id> --exit-status`. Never poll in a loop.

## Pitfalls

- `print_s` under `open! Async` in a `Command.basic` body never flushes; use `Core.print_s` or `Command.async`.
- On the ox Async, `Clock_ns.with_timeout` returns `Clock_ns.Or_timeout.t`; annotate it.
- Concatenated zstd frames decode as one stream, so appending a frame is a valid restart; the binding's
  decompressed-size call reads only the first frame.
- `on_raw` callbacks carry no symbol, so per-symbol raw files need one websocket per symbol.
- Hyperliquid `bbo` gets no raw frames when `l2` is subscribed (the client writes each `l2Book` once);
  the health check excludes that stream.
- `hl-sim` serves no `activeAssetCtx`, so a Hyperliquid funding stream never delivers against the simulator.

## Where to read more

- `README.md` (layout, venues, configuration, monitoring, rebuild, merge, throughput)
- `../specs/repos/market-recorder.md` (design, metrics history, known gaps)
- `../specs/design/data-platform.md`, `../specs/design/cloud-sinks-and-replication.md`
- `../specs/adr/0002-raw-first-storage.md`, `0004-tardis-compatible-raw-format.md`, `0005-command-based-uploader.md`
- `../oxcaml-claude-skills/AGENTS.md` and `../oxcaml-claude-skills/GOTCHAS.md`

## Never do

- Run `scripts/e2e-mainnet.sh` or the real-venue config unless the task asks; it opens real connections.
- Put credentials in a config or an example; the configs in `examples/` hold none.
- Run `opam install`, `upgrade` or `pin` that would change `ocaml-variants`, `core`, `base`, `async` or
  `ppx_jane` on the shared `5.2.0+ox` switch.
- Publish, tag or release.
- Poll CI in a loop.
