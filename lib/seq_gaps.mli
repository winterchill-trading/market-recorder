(** Exact gaps in a venue sequence ({!Venue_seq.check}), as the merge reports them.

    Messages may arrive slightly out of sequence order (two collectors' copies merged by
    [recv_ts]), so checks are held in a reorder buffer and applied in sequence order once
    they are [reorder] older than the newest [recv_ts] seen. A message whose [prev] is
    beyond the last applied sequence number leaves a gap: the numbers after the last one
    up to [prev] were never seen. Older or repeated numbers are ignored; a {!Restart}
    applies everything buffered, then restarts the sequence. *)

open! Core

module Gap : sig
  type t =
    { first_missing : int
    ; last_missing : int
    ; at : Time_ns.t (** [recv_ts] of the message after the gap *)
    }
  [@@deriving sexp_of, equal]
end

type t

val create : ?reorder:Time_ns.Span.t -> unit -> t
val add : t -> recv_ts:Time_ns.t -> Venue_seq.check -> unit

(** Applies everything still buffered. *)
val flush : t -> unit

(** Gaps found so far, in order. *)
val gaps : t -> Gap.t list

(** Forgets the gaps found so far but keeps the position in the sequence (after reading
    the previous day's last minute). *)
val clear_gaps : t -> unit
