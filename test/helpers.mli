open! Core
open! Async

(** A fresh temporary directory. *)
val temp_dir : unit -> string

(** Files under [dir], relative to it, sorted. *)
val tree : string -> string list Deferred.t

val print_tree : string -> unit Deferred.t

(** Contents of a single-frame [.zst] file. *)
val unzstd : string -> string Deferred.t

val time : string -> Time_ns.t
