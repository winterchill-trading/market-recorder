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

let respond ?max_age ?(process_metrics = Process_metrics.render) ?status metrics ~path
  : Response.t
  =
  match path with
  | "/healthz" ->
    let health = Metrics.health ?max_age metrics in
    let flush_error = Metrics.flush_error metrics in
    let max_age = Option.value max_age ~default:Metrics.default_max_age in
    let flush_failing =
      Option.exists flush_error ~f:(fun e -> Time_ns.Span.( <= ) e.age max_age)
    in
    let status =
      match health, flush_failing with
      | Healthy, false -> `OK
      | Stale _, _ | _, true -> `Service_unavailable
    in
    let lines =
      (match health, flush_failing with
       | Healthy, false -> [ "ok" ]
       | Healthy, true -> []
       | Stale _, _ -> [ Sexp.to_string_hum [%sexp (health : Metrics.Health.t)] ])
      @ Option.to_list
          (Option.map flush_error ~f:(fun e ->
             Sexp.to_string_hum
               (List [ Atom "last_flush_error"; [%sexp (e : Metrics.Flush_error.t)] ])))
    in
    { status
    ; content_type = text
    ; body = String.concat (List.map lines ~f:(fun l -> l ^ "\n"))
    }
  | "/metrics" ->
    { status = `OK
    ; content_type = "text/plain; version=0.0.4; charset=utf-8"
    ; body = Metrics.render metrics ^ process_metrics ()
    }
  | "/status" when Option.is_some status ->
    let status = Option.value_exn status in
    { status = `OK; content_type = text; body = Sexp.to_string_hum (status ()) ^ "\n" }
  | _ -> { status = `Not_found; content_type = text; body = "not found\n" }
;;

type t = (Socket.Address.Inet.t, int) Cohttp_async.Server.t

let start ?process_metrics ?status ~port metrics =
  Cohttp_async.Server.create
    ~on_handler_error:`Ignore
    (Tcp.Where_to_listen.of_port port)
    (fun ~body:_ _ request ->
       let path = Uri.path (Cohttp.Request.uri request) in
       let { Response.status; content_type; body } =
         respond ?process_metrics ?status metrics ~path
       in
       Cohttp_async.Server.respond_string
         ~status
         ~headers:(Cohttp.Header.of_list [ "content-type", content_type ])
         body)
;;

let port = Cohttp_async.Server.listening_on
let close = Cohttp_async.Server.close
