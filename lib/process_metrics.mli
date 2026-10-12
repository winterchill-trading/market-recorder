(** Process-wide gauges for [/metrics], read when rendering. *)

open! Core

(** [git describe] of the source tree at build time as dune records it ([unknown] when
    built outside a git checkout, e.g. from an opam archive). *)
val version : unit -> string

(** Prometheus text for the process gauges. *)
val render : unit -> string
