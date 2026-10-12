open! Core
open! Async
open Market_recorder
open Helpers

let%expect_test "healthz and metrics over http" =
  let now = ref (time "2026-10-12T09:00:00Z") in
  let metrics = Metrics.create ~now:(fun () -> !now) () in
  let key : Metrics.Key.t = { venue = Bybit; stream = Bbo; symbol = "BTCUSDT" } in
  Metrics.register metrics key;
  Metrics.frame metrics key ~recv_ts:!now ~bytes:10;
  let%bind server = Http_server.start ~process_metrics:(fun () -> "") ~port:0 metrics in
  let get path =
    let uri =
      Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port:(Http_server.port server) ~path ()
    in
    let%bind response, body = Cohttp_async.Client.get uri in
    let%map body = Cohttp_async.Body.to_string body in
    let status = Cohttp.Code.code_of_status (Cohttp.Response.status response) in
    let content_type =
      Cohttp.Header.get (Cohttp.Response.headers response) "content-type"
    in
    printf "%d %s\n%s" status (Option.value content_type ~default:"-") body
  in
  let%bind () = get "/healthz" in
  [%expect {|
    200 text/plain; charset=utf-8
    ok
    |}];
  now := time "2026-10-12T09:01:00Z";
  let%bind () = get "/healthz" in
  [%expect
    {|
    503 text/plain; charset=utf-8
    (Stale
     (((key ((venue Bybit) (stream Bbo) (symbol BTCUSDT))) (last_frame_age 1m)
       (frames 1))))
    |}];
  let%bind () = get "/metrics" in
  [%expect
    {|
    200 text/plain; version=0.0.4; charset=utf-8
    # HELP market_recorder_frames_total Raw frames received.
    # TYPE market_recorder_frames_total counter
    market_recorder_frames_total{venue="bybit",stream="bbo",symbol="BTCUSDT"} 1
    # HELP market_recorder_bytes_total Bytes of raw frames received.
    # TYPE market_recorder_bytes_total counter
    market_recorder_bytes_total{venue="bybit",stream="bbo",symbol="BTCUSDT"} 10
    # HELP market_recorder_events_total Normalized events written.
    # TYPE market_recorder_events_total counter
    market_recorder_events_total{venue="bybit",stream="bbo",symbol="BTCUSDT"} 0
    # HELP market_recorder_clamped_frames_total Raw frames whose recv_ts went backwards and was raised to the previous one.
    # TYPE market_recorder_clamped_frames_total counter
    market_recorder_clamped_frames_total{venue="bybit",stream="bbo",symbol="BTCUSDT"} 0
    # HELP market_recorder_norm_pipe_length Normalized events waiting in the pipe to the event log writer.
    # TYPE market_recorder_norm_pipe_length gauge
    market_recorder_norm_pipe_length{venue="bybit",stream="bbo",symbol="BTCUSDT"} 0
    # HELP market_recorder_last_frame_age_seconds Seconds since the last raw frame (since start if none yet).
    # TYPE market_recorder_last_frame_age_seconds gauge
    market_recorder_last_frame_age_seconds{venue="bybit",stream="bbo",symbol="BTCUSDT"} 60.000
    |}];
  let%bind () = get "/nope" in
  [%expect {|
    404 text/plain; charset=utf-8
    not found
    |}];
  Http_server.close server
;;

let%expect_test "healthz reports the last raw writer failure and its age" =
  let now = ref (time "2026-10-12T09:00:00Z") in
  let metrics = Metrics.create ~now:(fun () -> !now) () in
  let key : Metrics.Key.t = { venue = Okx; stream = Trades; symbol = "BTC-USDT" } in
  Metrics.register metrics key;
  Metrics.frame metrics key ~recv_ts:!now ~bytes:1;
  let failure = ref None in
  Metrics.set_flush_error_source metrics (fun () -> !failure);
  let show () =
    let { Http_server.Response.status; body; _ } =
      Http_server.respond metrics ~path:"/healthz"
    in
    printf "%d\n%s" (Cohttp.Code.code_of_status status) body
  in
  show ();
  [%expect {|
    200
    ok
    |}];
  failure := Some (Error.of_string "No space left on device", !now);
  now := time "2026-10-12T09:00:05Z";
  Metrics.frame metrics key ~recv_ts:!now ~bytes:1;
  show ();
  [%expect
    {|
    503
    (last_flush_error ((error "No space left on device") (age 5s)))
    |}];
  now := time "2026-10-12T09:00:40Z";
  Metrics.frame metrics key ~recv_ts:!now ~bytes:1;
  show ();
  [%expect
    {|
    200
    ok
    (last_flush_error ((error "No space left on device") (age 40s)))
    |}];
  return ()
;;
