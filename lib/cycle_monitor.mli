(** Long Async cycles: a cycle over [count_above] (50ms) is counted on [/metrics]
    ([market_recorder_long_cycles_total]); one over [warn_above] (20ms) is logged, at most
    once per [warn_every] (10s) with the number of warnings suppressed since. *)

open! Core
open! Async

type t

val create
  :  ?count_above:Time_ns.Span.t
  -> ?warn_above:Time_ns.Span.t
  -> ?warn_every:Time_ns.Span.t
  -> ?now:(unit -> Time_ns.t)
  -> ?warn:(Sexp.t -> unit)
  -> unit
  -> t

(** Records one cycle's duration. *)
val observe : t -> Time_ns.Span.t -> unit

(** Feeds {!observe} from [Scheduler.long_cycles]. *)
val start : t -> unit

val long_cycles : t -> int

(** The longest cycle observed over [warn_above]. *)
val longest : t -> Time_ns.Span.t

(** Adds [market_recorder_long_cycles_total] and [market_recorder_longest_cycle_seconds]. *)
val register : t -> Metrics.t -> unit
