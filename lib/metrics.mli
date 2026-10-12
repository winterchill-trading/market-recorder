(** Per venue, stream and symbol counters, rendered in the Prometheus text format, and the
    health rule.

    Parse errors and reconnects are handled inside the venue clients and are not visible
    through {!Market_data.Feed.t}, so they are not counted here. *)

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

(** Declares an expected stream; health requires a recent frame from every one. *)
val register : t -> Key.t -> unit

val frame : t -> Key.t -> recv_ts:Time_ns.t -> bytes:int -> unit
val event : t -> Key.t -> unit

(** Uploader gauges, read when rendering. *)
val set_upload_source : t -> (unit -> int * int * int) -> unit

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
    30s). *)
val health : ?max_age:Time_ns.Span.t -> t -> Health.t

(** Prometheus text exposition format 0.0.4. *)
val render : t -> string
