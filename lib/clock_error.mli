(** The host clock's error bound, sampled from chrony, for [/metrics] and for choosing
    [merge -clock-error] (see specs/design/cloud-sinks-and-replication.md, "Clock bound").

    The bound is [|system time offset| + root delay / 2 + root dispersion], the largest
    error chrony allows for the system clock, from the CSV of [chronyc -c tracking]. *)

open! Core
open! Async

(** The bound from one line of [chronyc -c tracking]. *)
val parse_tracking : string -> Time_ns.Span.t Or_error.t

type t

(** Runs [command] (default [chronyc -c tracking]) every [interval] (default 30s). If the
    first run fails (no chrony on the host) sampling stops and {!latest} stays [None]; a
    later failure clears {!latest} until a run succeeds again. *)
val start : ?command:string * string list -> ?interval:Time_ns.Span.t -> unit -> t

val latest : t -> Time_ns.Span.t option

(** Waits for the first run to finish. *)
val ready : t -> unit Deferred.t

val stop : t -> unit

(** Adds [market_recorder_clock_error_seconds] to the metrics. *)
val register : t -> Metrics.t -> unit
