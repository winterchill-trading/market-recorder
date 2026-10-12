(** A local websocket server that records what clients send, for recorder tests. *)

open! Core
open! Async

type t

val start : unit -> t Deferred.t
val port : t -> int

(** Websocket connections accepted so far. *)
val connections : t -> int

(** Text frames received from clients, in order. *)
val received : t -> string list

(** Sends a frame on every open connection. *)
val send_all : t -> string -> unit

(** Closes every open websocket connection. *)
val drop_all : t -> unit Deferred.t

val wait_until : ?timeout:Time_ns.Span.t -> (unit -> bool) -> bool Deferred.t
val close : t -> unit Deferred.t
