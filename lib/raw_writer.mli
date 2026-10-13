(** Raw venue frames in Tardis-style minute files.

    Each line is [<recv_ts> <frame>], [recv_ts] in ISO 8601 UTC with microseconds
    ([2026-10-12T09:15:02.123456Z]) and the frame exactly as the venue sent it. An empty
    line records a disconnect. There is one file per venue, stream, symbol and UTC minute
    of [recv_ts]:

    {v <data_dir>/raw/<venue>/<stream>/<symbol>/<YYYY>/<MM>/<DD>/<HH>-<MM>.ndjson v}

    With a [collector] id the name is [<HH>-<MM>.<collector>.ndjson], so two collectors
    recording the same venue never write the same object ({!Raw_files} reads both forms).

    Lines are buffered in memory and handed to the OS every [flush_interval] (default
    250ms) or when a buffer passes 1 MiB. When a minute is over (a frame of a later minute
    arrives, or the periodic tick sees the wall clock past it) the file is closed,
    compressed to [.ndjson.zst], the plain file removed, and the compressed path passed to
    [on_closed]. If the [.zst] already exists (a restart within the same minute) the new
    zstd frame is appended to it; [zstd -d] reads concatenated frames as one stream. *)

open! Core
open! Async

type t

val create
  :  ?flush_interval:Time_ns.Span.t
  -> ?now:(unit -> Time_ns.t)
  -> ?on_error:
       (venue:Market_data.Venue.t
        -> stream:Market_data.Stream.t
        -> symbol:string
        -> Error.t
        -> unit)
  -> ?collector:string (** checked with {!Raw_files.check_collector} by the caller *)
  -> data_dir:string
  -> on_closed:(string -> unit)
  -> unit
  -> t

(** Appends one frame. Newlines inside [frame] are replaced by spaces so that a line is
    always one record. *)
val write
  :  t
  -> venue:Market_data.Venue.t
  -> stream:Market_data.Stream.t
  -> symbol:string
  -> recv_ts:Time_ns.t
  -> string
  -> unit

(** Appends an empty line to the file of the current minute. *)
val disconnect
  :  t
  -> venue:Market_data.Venue.t
  -> stream:Market_data.Stream.t
  -> symbol:string
  -> recv_ts:Time_ns.t
  -> unit

(** One stream's minute files, looked up once (when a feed subscribes) so that writing a
    frame does not hash the venue, stream and symbol. *)
module Handle : sig
  type t
end

val handle
  :  t
  -> venue:Market_data.Venue.t
  -> stream:Market_data.Stream.t
  -> symbol:string
  -> Handle.t

(** {!write} through a handle. Once the minute's file is open the only allocation is the
    line's bytes in the file's buffer. *)
val write_handle : t -> Handle.t -> recv_ts:Time_ns.t -> string -> unit

(** {!disconnect} through a handle. *)
val disconnect_handle : t -> Handle.t -> recv_ts:Time_ns.t -> unit

(** Hands all buffered lines to the OS. *)
val flush : t -> unit Deferred.t

(** Closes and compresses files whose minute is before [now ()]. Called by the periodic
    tick; exposed for tests. *)
val roll : t -> unit Deferred.t

(** Stops the tick, closes and compresses every open file. Idempotent. *)
val close : t -> unit Deferred.t

(** The last failure to open, write, close or compress a minute file, and when it happened
    ([now ()]). Lines of a file that could not be opened are dropped; every failure is
    also passed to [on_error]. *)
val last_error : t -> (Error.t * Time_ns.t) option

val error_count : t -> int

(** Plain files currently open, sorted. *)
val open_files : t -> string list

(** Compresses every [.ndjson] left under [<data_dir>/raw] by an earlier run (to be called
    before {!create}), passing each compressed path to [on_closed]. Returns them, sorted. *)
val recover : data_dir:string -> on_closed:(string -> unit) -> string list Deferred.t

(** [path ~data_dir ~venue ~stream ~symbol minute] is the plain file holding [minute]. *)
val path
  :  ?collector:string
  -> data_dir:string
  -> venue:Market_data.Venue.t
  -> stream:Market_data.Stream.t
  -> symbol:string
  -> Time_ns.t
  -> string

(** [2026-10-12T09:15:02.123456Z] *)
val format_ts : Time_ns.t -> string

(** Compresses [path] to [path ^ ".zst"] (appending a frame if that exists), removes
    [path] and returns the compressed path. *)
val compress_file : string -> string Deferred.t
