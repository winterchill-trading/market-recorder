(** Wires the configured venues to the writers.

    One live feed is opened per venue entry and symbol, so every raw frame is known to
    belong to one symbol. Its [on_raw] callback goes to {!Raw_writer} and the counters;
    its normalized pipes go to {!Norm_writer}. Closed raw minute files go to the
    {!Uploader} when an upload command is configured. *)

open! Core
open! Async

type t

(** Compresses plain files left by an earlier run, then connects every feed. Fails if a
    first connection fails. *)
val start : Config.t -> t Deferred.t

val metrics : t -> Metrics.t

(** Closes the feeds, writes a disconnect line to every stream that received data,
    compresses the open minutes, closes the event logs and saves the upload queue.
    Idempotent. *)
val stop : t -> unit Deferred.t
