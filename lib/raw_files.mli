(** Raw minute files with an optional collector id in their name:

    {v
<HH>-<MM>.ndjson[.zst]               written without a collector id
       <HH>-<MM>.<collector>.ndjson[.zst]   written with -collector <collector>
    v}

    [Market_data.Raw_minute.files] lists only the first form; {!files} lists either one
    collector's files or the unnamed ones, so one tree can hold several collectors' copies
    (after cross-region replication into one bucket). *)

open! Core
open! Async

(** A collector id is 1 to 32 characters of [A-Za-z0-9_]. *)
val check_collector : string -> unit Or_error.t

val collector_arg : string Command.Arg_type.t

(** [(collector, plain_name)] of a minute file name, e.g. [13-35.a.ndjson.zst] is
    [(Some "a", "13-35.ndjson.zst")]; [None] if it is not a minute file name. *)
val parse_name : string -> (string option * string) option

(** Like [Market_data.Raw_minute.files], for the files of [collector] (or those without a
    collector id when [None]). Each file's [path] is its real path. *)
val files
  :  ?collector:string
  -> data_dir:string
  -> Date.t
  -> Market_data.Raw_minute.File.t list Deferred.t
