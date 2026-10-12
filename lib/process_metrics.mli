(** Process-wide gauges for [/metrics], read when rendering. *)

open! Core

(** [git describe] of the source tree at build time as dune records it ([unknown] when
    built outside a git checkout, e.g. from an opam archive). *)
val version : unit -> string

(** Open file descriptors of this process, from [/proc/self/fd] or [/dev/fd]. *)
val open_fds : unit -> int option

(** Resident set size from [/proc/self/statm]; [None] where that does not exist. *)
val rss_bytes : unit -> int option

(** Prometheus text for the process gauges. *)
val render : unit -> string
