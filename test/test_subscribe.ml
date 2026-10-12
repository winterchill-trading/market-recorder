(* Subscribe frames the recorder's feeds send at connect and after a reconnect, against a
   local websocket server standing in for Binance. *)

open! Core
open! Async
open Market_recorder

let%expect_test "three symbols and two streams subscribe once each at connect and again \
                 on reconnect"
  =
  Log.Global.set_output [];
  let%bind server = Fake_ws.start () in
  let dir = Helpers.temp_dir () in
  let config =
    Config.of_sexp
      (Sexp.of_string
         (sprintf
            {|((data_dir %s) (http_port 0)
               (venues (((venue Binance) (symbols (BTCUSDT ETHUSDT SOLUSDT))
                         (streams (Trades Bbo))
                         (config (Custom (base_url http://127.0.0.1:%d)))))))|}
            dir
            (Fake_ws.port server)))
    |> Or_error.ok_exn
  in
  let%bind recorder = Recorder.start config in
  (* one connection per symbol and stream; request ids depend on the order *)
  let subscribes () =
    List.filter (Fake_ws.received server) ~f:(String.is_substring ~substring:"SUBSCRIBE")
    |> List.map ~f:(fun frame -> fst (String.rsplit2_exn frame ~on:','))
  in
  let%bind (_ : bool) = Fake_ws.wait_until (fun () -> List.length (subscribes ()) = 6) in
  let at_connect = subscribes () in
  print_s
    [%message
      "connect"
        ~connections:(Fake_ws.connections server : int)
        ~subscribes:(List.sort at_connect ~compare:String.compare : string list)];
  [%expect
    {|
    (connect (connections 6)
     (subscribes
      ("{\"method\":\"SUBSCRIBE\",\"params\":[\"btcusdt@aggTrade\"]"
       "{\"method\":\"SUBSCRIBE\",\"params\":[\"btcusdt@bookTicker\"]"
       "{\"method\":\"SUBSCRIBE\",\"params\":[\"ethusdt@aggTrade\"]"
       "{\"method\":\"SUBSCRIBE\",\"params\":[\"ethusdt@bookTicker\"]"
       "{\"method\":\"SUBSCRIBE\",\"params\":[\"solusdt@aggTrade\"]"
       "{\"method\":\"SUBSCRIBE\",\"params\":[\"solusdt@bookTicker\"]")))
    |}];
  let%bind () = Fake_ws.drop_all server in
  (* the first reconnect backoff is 0.5 s with jitter *)
  let%bind (_ : bool) =
    Fake_ws.wait_until ~timeout:(Time_ns.Span.of_int_sec 10) (fun () ->
      List.length (subscribes ()) = 12)
  in
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 200) in
  let again = List.drop (subscribes ()) 6 in
  print_s
    [%message
      "reconnect"
        ~connections:(Fake_ws.connections server : int)
        ~subscribes:(List.length (subscribes ()) : int)
        ~same_frames:
          ([%equal: string list]
             (List.sort again ~compare:String.compare)
             (List.sort at_connect ~compare:String.compare)
           : bool)];
  [%expect {| (reconnect (connections 12) (subscribes 12) (same_frames true)) |}];
  let%bind () = Recorder.stop recorder in
  Fake_ws.close server
;;
