(** Normalized events into {!Market_data.Event_log} daily files under [data_dir]
    ([<data_dir>/<venue>/<symbol>/norm/<stream>/<YYYY-MM-DD>.bin]), the layout the
    market-data tools read. *)

open! Core
open! Async

type t

(** [flush_interval] defaults to 250ms. Every [snapshot_interval] (default one minute;
    zero turns it off) the full L2 book of each instrument with L2 updates is written to
    its [Market_data.Snapshot_index] file
    ([<venue>/<symbol>/norm/l2/_snapshots/<date>.bin]), so a replay can start from the
    last snapshot. *)
val create
  :  ?flush_interval:Time_ns.Span.t
  -> ?snapshot_interval:Time_ns.Span.t
  -> data_dir:string
  -> unit
  -> t

val append : t -> Market_data.Event.t -> unit

(** Reads every pipe of [feed] until it closes, appending each event and calling
    [on_event] after it. Determined when all four pipes are closed. *)
val consume
  :  t
  -> Market_data.Feed.t
  -> on_event:(Market_data.Event.t -> unit)
  -> unit Deferred.t

val flush : t -> unit Deferred.t
val close : t -> unit Deferred.t
val files : t -> string list

(** Snapshot files opened so far, sorted. *)
val snapshot_files : t -> string list
