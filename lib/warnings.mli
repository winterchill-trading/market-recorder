(** Per-stream warning log that repeats itself at most once per [interval].

    The first warning of a stream is logged at once. Later ones within [interval] of the
    last logged one are only counted; the next warning after that is logged with the
    number suppressed in between, so a stream stuck in a failure loop writes one line a
    minute instead of one per frame. *)

open! Core

type t

(** [interval] defaults to one minute, [now] to [Time_ns.now] and [log] to
    [Log.Global.error_s]. *)
val create
  :  ?interval:Time_ns.Span.t
  -> ?now:(unit -> Time_ns.t)
  -> ?log:(Sexp.t -> unit)
  -> unit
  -> t

val warn : t -> Metrics.Key.t -> Sexp.t -> unit

(** Warnings counted but not logged so far, over all streams. *)
val suppressed : t -> int
