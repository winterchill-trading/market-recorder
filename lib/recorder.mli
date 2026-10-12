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

module Status : sig
  type t =
    { open_minute_files : string list (** relative to [data_dir] *)
    ; pending_uploads : string list (** relative to [data_dir] *)
    ; streams : Metrics.Stream_status.t list
    ; clients : (Market_data.Venue.t * Metrics.Feed_stats.t) list
    (** each venue client's frames, parse errors and reconnects, summed over its feeds *)
    }
  [@@deriving sexp_of]

  (** [streams] and [clients] read from the metrics. *)
  val create
    :  open_minute_files:string list
    -> pending_uploads:string list
    -> Metrics.t
    -> t
end

val status : t -> Status.t

(** Closes the feeds, writes a disconnect line to every stream that received data,
    compresses the open minutes, closes the event logs, gives pending uploads up to 10s
    and saves the rest of the upload queue. Idempotent. *)
val stop : t -> unit Deferred.t
