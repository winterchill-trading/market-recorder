(** Uploads closed files by running an external command (e.g. [rclone copyto]).

    Each file is uploaded by running [command] with [{file}] replaced by its path and
    [{rel}] by its path relative to [data_dir]. A failed run is retried after a backoff
    that starts at [initial_backoff] (default 1s) and doubles up to [max_backoff] (default
    5 min). At most [max_concurrent] (default 4) commands run at once. After a success the
    file is deleted when [delete_after_upload] is set.

    Files not yet uploaded are kept in [<data_dir>/upload-pending.sexp], rewritten on
    every change, so a restart re-uploads them. *)

open! Core
open! Async

type t

(** Loads the pending list of an earlier run (dropping files that no longer exist) and
    starts uploading it. *)
val create
  :  ?max_concurrent:int
  -> ?initial_backoff:Time_ns.Span.t
  -> ?max_backoff:Time_ns.Span.t
  -> data_dir:string
  -> Config.Upload.t
  -> t Deferred.t

(** Queues a file. A file already pending is not queued twice. *)
val enqueue : t -> string -> unit

(** Files queued and not yet uploaded, sorted. *)
val pending : t -> string list

val uploaded : t -> int

(** Failed command runs (each retry counts). *)
val failures : t -> int

(** Determined once nothing is pending (or [t] is closed). *)
val idle : t -> unit Deferred.t

(** Stops retrying and starting uploads, waits up to [timeout] (default 10s) for running
    commands, and saves the pending list. *)
val close : ?timeout:Time_ns.Span.t -> t -> unit Deferred.t

(** The command line for one file. *)
val command_for : command:string list -> file:string -> rel:string -> string list

(** [file] relative to [data_dir], or its base name if it is outside. *)
val relative : data_dir:string -> string -> string

val pending_file : data_dir:string -> string
