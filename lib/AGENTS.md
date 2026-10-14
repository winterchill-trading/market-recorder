# lib: market-recorder library

Library `market-recorder` (module `Market_recorder`). The per-frame path is `Recorder`: one
`Live_feed` per venue entry and symbol, `on_raw` to `Raw_writer`, and the client's pipe to
`Norm_writer`. Other groups:

- Writers and upload: `Raw_writer` (minute files, 250 ms flush, zstd roll, crash recovery), `Norm_writer`
  (event logs and per-minute L2 snapshots), `Uploader` (one command per closed file, backoff, four at once).
- Checks: `Venue_seq`, `Seq_gaps`, `Silence`, `Clock_error`, `Cycle_monitor`, `Warnings`.
- Observability: `Metrics`, `Process_metrics`, `Http_server` (`/healthz`, `/metrics`, `/status`).
- Replication and rebuild: `Raw_files`, `Raw_merge`, `Rebuild`.

Rules:

- `recv_ts` is clamped to non-decreasing per stream and each clamp is counted; do not hide it.
- A gap from a client becomes a disconnect line in the open minute file of every stream it covers.
- `Raw_writer` writes buffered lines only once the minute file is open. A close right after the first
  write once failed on Linux; keep the test that covers it.
- A stalled event log does not push back on the feeds; events wait in memory and a test pins it.
