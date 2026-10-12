(** Merges the raw minute files of two collectors recording the same venues into one
    canonical copy (see specs/design/cloud-sinks-and-replication.md).

    Per venue, stream, symbol and minute:

    - Frames are matched by their text: a frame of copy A and a frame of copy B with the
      same text whose [recv_ts] differ by at most [window] are one venue message, written
      once with the earlier [recv_ts]. Repeated identical frames pair up in time order.
      Frames near the end of a minute are also matched against the next minute of the
      other copy, so a message stamped on both sides of a minute boundary is kept once.
    - A disconnect line spans from the previous frame of its file (or the start of the
      minute) to the next one (or the end of the minute). It is kept only when the other
      copy has a gap overlapping that span (its own disconnect, or no file for that
      minute); otherwise the other copy filled it and the line is dropped.
    - Output lines are ordered by [recv_ts]; ties keep copy A first. *)

open! Core
open! Async

module Counts : sig
  type t =
    { minutes : int (** minute files written *)
    ; only_a : int (** frames found only in copy A *)
    ; only_b : int
    ; both : int (** frames found in both copies, written once *)
    ; gaps_closed : int (** disconnect lines dropped because the other copy had frames *)
    ; gaps_kept : int (** disconnect lines written: both copies had a gap *)
    }
  [@@deriving sexp_of, equal]

  val zero : t
  val ( + ) : t -> t -> t
end

(** Unmatched frames of the last [window] of a minute, offered to the next minute. *)
module Carry : sig
  type t

  val empty : t
end

(** Merges one minute. [None] means that copy has no file for the minute. The [Counts.t]
    is a correction relative to earlier minutes when a frame matches a carried one (its
    [only_*] count can be negative); sums over a series are exact. *)
val merge_minute
  :  window:Time_ns.Span.t
  -> minute:Time_ns.t
  -> Carry.t
  -> a:Market_data.Raw_minute.Line.t list option
  -> b:Market_data.Raw_minute.Line.t list option
  -> Market_data.Raw_minute.Line.t list * Counts.t * Carry.t
