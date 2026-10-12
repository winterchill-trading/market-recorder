open! Core
open! Async

module Response = struct
  type t =
    { status : Cohttp.Code.status_code
    ; content_type : string
    ; body : string
    }
  [@@deriving sexp_of]
end

let text = "text/plain; charset=utf-8"

let respond metrics ~path : Response.t =
  match path with
  | "/healthz" ->
    (match Metrics.health metrics with
     | Healthy -> { status = `OK; content_type = text; body = "ok\n" }
     | Stale _ as health ->
       { status = `Service_unavailable
       ; content_type = text
       ; body = Sexp.to_string_hum [%sexp (health : Metrics.Health.t)] ^ "\n"
       })
  | "/metrics" ->
    { status = `OK
    ; content_type = "text/plain; version=0.0.4; charset=utf-8"
    ; body = Metrics.render metrics
    }
  | _ -> { status = `Not_found; content_type = text; body = "not found\n" }
;;

type t = (Socket.Address.Inet.t, int) Cohttp_async.Server.t

let start ~port metrics =
  Cohttp_async.Server.create
    ~on_handler_error:`Ignore
    (Tcp.Where_to_listen.of_port port)
    (fun ~body:_ _ request ->
       let path = Uri.path (Cohttp.Request.uri request) in
       let { Response.status; content_type; body } = respond metrics ~path in
       Cohttp_async.Server.respond_string
         ~status
         ~headers:(Cohttp.Header.of_list [ "content-type", content_type ])
         body)
;;

let port = Cohttp_async.Server.listening_on
let close = Cohttp_async.Server.close
