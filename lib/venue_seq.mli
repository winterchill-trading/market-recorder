(** Venue sequence numbers read from raw frames, for the merge (see
    specs/design/cloud-sinks-and-replication.md, "Gap detection").

    - Binance [l2] ([depthUpdate]): identity [u]; each event's [pu] must equal the
      previous event's [u]. REST snapshots ([lastUpdateId]) have no identity.
    - Binance [trades] ([aggTrade]): identity and contiguous sequence [a].
    - Bybit [l2] ([orderbook.<depth>]): identity is the message type and [u]; deltas
      continue [u] by one, a snapshot with [u = 1] restarts it (a service restart).
    - Everything else (Hyperliquid, Bybit trades and funding, other venues): no sequence;
      the merge identifies those frames by their text.

    Fields are found by scanning for the first ["key":] in the frame, not by parsing the
    JSON, so the cost per frame is a few substring searches. *)

open! Core

type check =
  | Chain of
      { prev : int (** the sequence number the previous message must have ended at *)
      ; last : int (** this message's own sequence number *)
      }
  | Restart of int (** a snapshot that restarts the sequence at this number *)
[@@deriving sexp_of, equal]

type t =
  { identity : string option (** the same message on two connections has the same key *)
  ; check : check option
  }
[@@deriving sexp_of, equal]

val none : t

(** Whether frames of this venue and stream carry a sequence the merge reads. *)
val has_sequence : venue:Market_data.Venue.t -> stream:Market_data.Stream.t -> bool

val of_frame : venue:Market_data.Venue.t -> stream:Market_data.Stream.t -> string -> t

(** The integer after the first ["key":] in [frame], if any (optionally quoted). *)
val field_int : string -> key:string -> int option
