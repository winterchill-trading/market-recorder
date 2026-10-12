(** Per venue, stream and symbol counters, rendered in the Prometheus text format, and the
    health rule.

    Parse errors and reconnects happen inside the venue clients; each client's counters
    are read through a {!Feed_stats} source per feed and summed per venue. *)

open! Core

module Key : sig
  type t =
    { venue : Market_data.Venue.t
    ; stream : Market_data.Stream.t
    ; symbol : string
    }
  [@@deriving sexp, compare, equal, hash]
end

type t

(** [now] defaults to [Time_ns.now]; it also stamps registration, so a stream that never
    delivered ages from when it was registered. *)
val create : ?now:(unit -> Time_ns.t) -> unit -> t

(** Declares an expected stream; health requires a recent frame from every one.

    [raw] (default [true]) is [false] for a stream whose frames are recorded under another
    stream, e.g. Hyperliquid [Bbo] next to [L2] (both come from the same [l2Book] frames,
    written once under [L2]). Such a stream only counts normalized events: it is left out
    of the health rule and of the raw frame metrics. *)
val register : ?raw:bool -> t -> Key.t -> unit

val frame : t -> Key.t -> recv_ts:Time_ns.t -> bytes:int -> unit

(** [clamp_recv_ts t key recv_ts] is [recv_ts], or the [recv_ts] of the last {!frame} of
    [key] when that is later (the wall clock stepped back), counting each such frame.
    Keeps the receive times of a stream non-decreasing. *)
val clamp_recv_ts : t -> Key.t -> Time_ns.t -> Time_ns.t

val event : t -> Key.t -> unit

(** Where the [norm_pipe_length] gauge of a stream reads its pipe length from. *)
val set_pipe_length : t -> Key.t -> (unit -> int) -> unit

(** Uploader gauges, read when rendering. *)
val set_upload_source : t -> (unit -> int * int * int) -> unit

(** Where {!flush_error} reads the last raw writer failure and its time from. *)
val set_flush_error_source : t -> (unit -> (Error.t * Time_ns.t) option) -> unit

(** The counters a venue client keeps for one feed. *)
module Feed_stats : sig
  type t =
    { frames : int (** websocket text frames received, acks included *)
    ; parse_errors : int (** frames dropped as undecodable or error responses *)
    ; reconnects : int (** successful reconnections, the first connection excluded *)
    }
  [@@deriving sexp_of, equal]

  val zero : t
  val ( + ) : t -> t -> t
end

(** Adds a feed of [venue] whose counters are read from [f] when rendering. *)
val add_feed_stats_source
  :  t
  -> venue:Market_data.Venue.t
  -> (unit -> Feed_stats.t)
  -> unit

(** The counters of every venue with a source, summed over its feeds, sorted by venue. *)
val feed_stats : t -> (Market_data.Venue.t * Feed_stats.t) list

module Flush_error : sig
  type t =
    { error : Error.t
    ; age : Time_ns.Span.t
    }
  [@@deriving sexp_of]
end

(** The last raw writer failure, if any, with its age. *)
val flush_error : t -> Flush_error.t option

module Health : sig
  type stale =
    { key : Key.t
    ; last_frame_age : Time_ns.Span.t
    ; frames : int
    }
  [@@deriving sexp_of]

  type t =
    | Healthy
    | Stale of stale list
  [@@deriving sexp_of]
end

(** [Stale] lists every registered stream without a frame in the last [max_age] (default
    30s). Each call also counts streams that turned stale since the previous call
    ([healthz_flaps_total]); {!render} calls it with the default [max_age]. *)
val default_max_age : Time_ns.Span.t

val health : ?max_age:Time_ns.Span.t -> t -> Health.t

module Stream_status : sig
  type t =
    { key : Key.t
    ; frames : int
    ; bytes : int
    ; events : int
    ; clamped : int
    ; flaps : int
    ; last_frame_age : Time_ns.Span.t (** since registration if no frame yet *)
    }
  [@@deriving sexp_of]
end

(** The counters of every stream, sorted by key. *)
val streams : t -> Stream_status.t list

(** Prometheus text exposition format 0.0.4. *)
val render : t -> string
