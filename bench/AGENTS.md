# bench: market-recorder throughput

`bench.ml` pushes one synthetic minute of Binance `BTCUSDT` frames through the normalizer, the raw
writer with its zstd roll and the event log writer. The README records the per-frame path numbers.

Rules:

- Quote the machine with every figure.
- Benchmarks do not run in CI; a change that moves a number updates the README in the same commit.
