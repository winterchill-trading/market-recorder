# bin: market-recorder CLI

`main.ml` defines the commands: `run -config FILE [-collector ID]`, `check-config -config FILE`,
`status [-url URL]`, `rebuild-norm -data-dir DIR -out DIR -date DATE [-venue V] [-skip VENUE:STREAM]`,
and `merge` (two collectors' days into one canonical copy).

`memtrace_start.real.ml` or `memtrace_start.none.ml` is chosen by dune. `MEMTRACE=FILE` starts memtrace
before Async, and infra's compose and Helm pass it.

Rules:

- `check-config` errors name the entry as `venues[i] <venue>: ...`. Keep that form.
