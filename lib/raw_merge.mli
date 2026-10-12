(** Merges the raw minute files of two collectors recording the same venues into one
    canonical copy (see specs/design/cloud-sinks-and-replication.md).

    Per venue, stream, symbol and minute:

    - Frames are matched by their identity: the venue sequence number where the stream has
      one ({!Venue_seq}: Binance [u] and [a], Bybit book [u]), else the frame text. A
      frame of copy A and a frame of copy B with the same identity whose [recv_ts] differ
      by at most [window] are one venue message, written once with the earlier [recv_ts].
      Repeated identical frames pair up in time order. Frames near the end of a minute are
      also matched against the next minute of the other copy, so a message stamped on both
      sides of a minute boundary is kept once.
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
    ; text_differs : int
    (** pairs matched by venue sequence whose frame texts differ (the earlier is kept) *)
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
  :  ?identity:(string -> string option)
       (** a frame's identity; [None] (the default for every frame) matches by text *)
  -> ?clock_error:Time_ns.Span.t
       (** the summed clock error bound of the two collectors (default zero): it widens
           [window], and when two copies' stamps differ by no more than it, copy A's is
           kept, since the clocks cannot say which came first *)
  -> window:Time_ns.Span.t
  -> minute:Time_ns.t
  -> Carry.t
  -> a:Market_data.Raw_minute.Line.t list option
  -> b:Market_data.Raw_minute.Line.t list option
  -> Market_data.Raw_minute.Line.t list * Counts.t * Carry.t

module Series : sig
  type t =
    { venue : Market_data.Venue.t
    ; stream : Market_data.Stream.t
    ; symbol_dir : string
    }
  [@@deriving sexp_of, compare, equal]
end

(** What the merge found in a series beyond the counts. *)
module Findings : sig
  type seq =
    { gaps : Seq_gaps.Gap.t list
    (** sequence numbers missing from the merged output: neither copy had them *)
    ; gaps_a : int (** gaps in copy A alone, filled where B had the messages *)
    ; gaps_b : int
    }
  [@@deriving sexp_of]

  type t =
    { seq : seq option (** for streams with a venue sequence *)
    ; median_interval : Time_ns.Span.t option (** between merged frames, see {!Silence} *)
    ; suspected : Silence.Gap.t list
    (** silences longer than [silence] in the merged output of a stream that ticks *)
    }
  [@@deriving sexp_of]
end

module Report : sig
  type t =
    { date : Date.t
    ; window : Time_ns.Span.t
    ; clock_error : Time_ns.Span.t
    ; series : (Series.t * Counts.t) list
    ; findings : (Series.t * Findings.t) list
    ; total : Counts.t
    }
  [@@deriving sexp_of]

  val to_json : t -> string
end

val default_window : Time_ns.Span.t
val default_silence : Time_ns.Span.t

(** Merges every raw minute file of the UTC [date] under [<a_dir>/raw] and [<b_dir>/raw]
    into [<out_dir>/raw] with {!Raw_writer} (compressed minute files), and writes the
    report to [<out_dir>/_merge/<date>.json] (counts, sequence gaps, suspected gaps from
    silences longer than [silence], default 10s). Fails without writing if [out_dir]
    already holds raw files of [date]. *)
val run
  :  ?window:Time_ns.Span.t
  -> ?silence:Time_ns.Span.t
  -> ?clock_error:Time_ns.Span.t
  -> a_dir:string
  -> b_dir:string
  -> out_dir:string
  -> Date.t
  -> Report.t Or_error.t Deferred.t

val command : Command.t
