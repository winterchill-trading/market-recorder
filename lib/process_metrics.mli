(** Process-wide gauges for [/metrics], read when rendering. *)

open! Core

(** [git describe] of the source tree at build time as dune records it ([unknown] when
    built outside a git checkout, e.g. from an opam archive). *)
val version : unit -> string

(** Open file descriptors of this process, from [/proc/self/fd] or [/dev/fd]. *)
val open_fds : unit -> int option

(** Soft and hard [RLIMIT_NOFILE] ([None] for unlimited); logged at startup and the soft
    one exported as [market_recorder_max_fds]. *)
val fd_limits : unit -> (int64 option * int64 option) option

(** Resident set size from [/proc/self/statm]; [None] where that does not exist. *)
val rss_bytes : unit -> int option

(** Prometheus text for the process gauges. *)
val render : unit -> string
