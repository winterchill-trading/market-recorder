(** The monitoring endpoint.

    - [GET /healthz]: [200 ok] when every recorded stream delivered a frame in the last
      30s and the raw writer has not failed in that time, else [503] with the stale
      streams as a sexp. The last raw writer failure and its age follow on their own line
      whenever there was one.
    - [GET /metrics]: {!Metrics.render}, as [text/plain; version=0.0.4].

    Anything else is [404]. *)

open! Core
open! Async

module Response : sig
  type t =
    { status : Cohttp.Code.status_code
    ; content_type : string
    ; body : string
    }
  [@@deriving sexp_of]
end

(** The response for a request path. *)
val respond : ?max_age:Time_ns.Span.t -> Metrics.t -> path:string -> Response.t

type t

(** Listens on [port] (0 picks a free one). *)
val start : port:int -> Metrics.t -> t Deferred.t

val port : t -> int
val close : t -> unit Deferred.t
