open! Core
open! Async

type t =
  { tcp : (Socket.Address.Inet.t, int) Tcp.Server.t
  ; mutable connections : int
  ; received : string Queue.t
  ; mutable open_ : (string Websocket.t * string Pipe.Writer.t) list
  }

let rec read_headers reader acc =
  match%bind Reader.read_line reader with
  | `Eof | `Ok "" -> return (List.rev acc)
  | `Ok line ->
    read_headers
      reader
      (match String.lsplit2 line ~on:':' with
       | Some (k, v) -> (String.lowercase k, String.strip v) :: acc
       | None -> acc)
;;

let handle t reader writer =
  let%bind (_ : string Reader.Read_result.t) = Reader.read_line reader in
  let%bind headers = read_headers reader [] in
  match List.Assoc.find headers ~equal:String.equal "sec-websocket-key" with
  | None -> Writer.close writer
  | Some key ->
    Writer.write
      writer
      (sprintf
         "HTTP/1.1 101 Switching Protocols\r\n\
          Upgrade: websocket\r\n\
          Connection: Upgrade\r\n\
          Sec-WebSocket-Accept: %s\r\n\
          \r\n"
         (Websocket.sec_websocket_accept_header_value ~sec_websocket_key:key));
    let ws = Websocket.create ~opcode:`Text ~role:Server reader writer in
    t.connections <- t.connections + 1;
    let from_client, to_client = Websocket.pipes ws in
    t.open_ <- (ws, to_client) :: t.open_;
    let%map () = Pipe.iter_without_pushback from_client ~f:(Queue.enqueue t.received) in
    t.open_ <- List.filter t.open_ ~f:(fun (w, _) -> not (phys_equal w ws))
;;

let start () =
  let t_ref = ref None in
  let%map tcp =
    Tcp.Server.create
      ~on_handler_error:`Ignore
      (Tcp.Where_to_listen.bind_to Localhost On_port_chosen_by_os)
      (fun _ reader writer -> handle (Option.value_exn !t_ref) reader writer)
  in
  let t = { tcp; connections = 0; received = Queue.create (); open_ = [] } in
  t_ref := Some t;
  t
;;

let port t = Tcp.Server.listening_on t.tcp
let connections t = t.connections
let received t = Queue.to_list t.received

let send_all t frame =
  List.iter t.open_ ~f:(fun (_, w) -> Pipe.write_without_pushback_if_open w frame)
;;

let drop_all t =
  let open_ = t.open_ in
  t.open_ <- [];
  Deferred.List.iter ~how:`Parallel open_ ~f:(fun (ws, _) ->
    Websocket.close ws ~code:Endpoint_going_away ~reason:"bye")
;;

let wait_until ?(timeout = Time_ns.Span.of_int_sec 5) f =
  let deadline = Time_ns.add (Time_ns.now ()) timeout in
  Deferred.repeat_until_finished () (fun () ->
    if f ()
    then return (`Finished true)
    else if Time_ns.( > ) (Time_ns.now ()) deadline
    then return (`Finished false)
    else (
      let%map () = Clock_ns.after (Time_ns.Span.of_int_ms 1) in
      `Repeat ()))
;;

let close t = Tcp.Server.close ~close_existing_connections:true t.tcp
