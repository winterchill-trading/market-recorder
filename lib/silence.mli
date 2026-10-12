(** Suspected gaps from silence: a stretch longer than [threshold] without a frame, on a
    stream that normally ticks.

    Intervals between frames go into a power-of-two histogram (microseconds), so a day of
    a busy stream costs constant memory. A stream "normally ticks" when its median
    interval (the upper edge of the median bucket) is at most a tenth of [threshold];
    silences of other streams are not reported, as a quiet trade stream is not a gap. The
    stretch from [start] to the first frame and from the last frame to [stop] count. *)

open! Core

module Gap : sig
  type t =
    { from : Time_ns.Alternate_sexp.t
    ; until : Time_ns.Alternate_sexp.t
    }
  [@@deriving sexp_of, equal]
end

type t

val create : threshold:Time_ns.Span.t -> start:Time_ns.t -> unit -> t
val add : t -> Time_ns.t -> unit

(** Closes the series at [stop] (the end of the day). *)
val finish : t -> stop:Time_ns.t -> unit

(** The median interval between frames, [None] with fewer than two frames. *)
val median_interval : t -> Time_ns.Span.t option

val ticks : t -> bool

(** Silences longer than [threshold], in order; empty unless the stream {!ticks}. *)
val suspected : t -> Gap.t list

(** Forgets intervals and silences but keeps the last frame time (after reading the
    previous day's last minute). *)
val restart : t -> unit
