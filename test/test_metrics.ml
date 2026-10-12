open! Core
open! Async
open Market_recorder
open Helpers

let%expect_test "counters, health and exposition" =
  let now = ref (time "2026-10-12T09:00:00Z") in
  let t = Metrics.create ~now:(fun () -> !now) () in
  let trades : Metrics.Key.t = { venue = Binance; stream = Trades; symbol = "BTCUSDT" } in
  let l2 : Metrics.Key.t = { venue = Hyperliquid; stream = L2; symbol = "BTC" } in
  Metrics.register t trades;
  Metrics.register t l2;
  now := time "2026-10-12T09:00:20Z";
  Metrics.frame t trades ~recv_ts:!now ~bytes:120;
  Metrics.frame t trades ~recv_ts:!now ~bytes:80;
  Metrics.event t trades;
  print_s [%sexp (Metrics.health t : Metrics.Health.t)];
  [%expect {| Healthy |}];
  now := time "2026-10-12T09:00:35Z";
  print_s [%sexp (Metrics.health t : Metrics.Health.t)];
  [%expect
    {|
    (Stale
     (((key ((venue Hyperliquid) (stream L2) (symbol BTC))) (last_frame_age 35s)
       (frames 0))))
    |}];
  Metrics.set_upload_source t (fun () -> 3, 1, 2);
  print_string (Metrics.render t);
  [%expect
    {|
    # HELP market_recorder_frames_total Raw frames received.
    # TYPE market_recorder_frames_total counter
    market_recorder_frames_total{venue="hyperliquid",stream="l2",symbol="BTC"} 0
    market_recorder_frames_total{venue="binance",stream="trades",symbol="BTCUSDT"} 2
    # HELP market_recorder_bytes_total Bytes of raw frames received.
    # TYPE market_recorder_bytes_total counter
    market_recorder_bytes_total{venue="hyperliquid",stream="l2",symbol="BTC"} 0
    market_recorder_bytes_total{venue="binance",stream="trades",symbol="BTCUSDT"} 200
    # HELP market_recorder_events_total Normalized events written.
    # TYPE market_recorder_events_total counter
    market_recorder_events_total{venue="hyperliquid",stream="l2",symbol="BTC"} 0
    market_recorder_events_total{venue="binance",stream="trades",symbol="BTCUSDT"} 1
    # HELP market_recorder_clamped_frames_total Raw frames whose recv_ts went backwards and was raised to the previous one.
    # TYPE market_recorder_clamped_frames_total counter
    market_recorder_clamped_frames_total{venue="hyperliquid",stream="l2",symbol="BTC"} 0
    market_recorder_clamped_frames_total{venue="binance",stream="trades",symbol="BTCUSDT"} 0
    # HELP market_recorder_norm_pipe_length Normalized events waiting in the pipe to the event log writer.
    # TYPE market_recorder_norm_pipe_length gauge
    market_recorder_norm_pipe_length{venue="hyperliquid",stream="l2",symbol="BTC"} 0
    market_recorder_norm_pipe_length{venue="binance",stream="trades",symbol="BTCUSDT"} 0
    # HELP market_recorder_last_frame_age_seconds Seconds since the last raw frame (since start if none yet).
    # TYPE market_recorder_last_frame_age_seconds gauge
    market_recorder_last_frame_age_seconds{venue="hyperliquid",stream="l2",symbol="BTC"} 35.000
    market_recorder_last_frame_age_seconds{venue="binance",stream="trades",symbol="BTCUSDT"} 15.000
    # HELP market_recorder_uploads_total Files uploaded.
    # TYPE market_recorder_uploads_total counter
    market_recorder_uploads_total 3
    # HELP market_recorder_upload_failures_total Failed upload command runs.
    # TYPE market_recorder_upload_failures_total counter
    market_recorder_upload_failures_total 1
    # HELP market_recorder_upload_pending Files waiting to be uploaded.
    # TYPE market_recorder_upload_pending gauge
    market_recorder_upload_pending 2
    |}];
  return ()
;;

let%expect_test "recv_ts is clamped to non-decreasing per stream" =
  let t = Metrics.create ~now:(fun () -> time "2026-10-12T09:00:00Z") () in
  let a : Metrics.Key.t = { venue = Bybit; stream = Bbo; symbol = "BTCUSDT" } in
  let b : Metrics.Key.t = { venue = Bybit; stream = Trades; symbol = "BTCUSDT" } in
  let feed key s =
    let recv_ts = Metrics.clamp_recv_ts t key (time s) in
    Metrics.frame t key ~recv_ts ~bytes:1;
    print_endline (Raw_writer.format_ts recv_ts)
  in
  feed a "2026-10-12T09:00:01Z";
  feed a "2026-10-12T09:00:00.5Z";
  feed a "2026-10-12T09:00:00.7Z";
  feed b "2026-10-12T09:00:00.1Z";
  feed a "2026-10-12T09:00:02Z";
  [%expect
    {|
    2026-10-12T09:00:01.000000Z
    2026-10-12T09:00:01.000000Z
    2026-10-12T09:00:01.000000Z
    2026-10-12T09:00:00.100000Z
    2026-10-12T09:00:02.000000Z
    |}];
  Metrics.render t
  |> String.split_lines
  |> List.filter ~f:(String.is_prefix ~prefix:"market_recorder_clamped")
  |> List.iter ~f:print_endline;
  [%expect
    {|
    market_recorder_clamped_frames_total{venue="bybit",stream="trades",symbol="BTCUSDT"} 0
    market_recorder_clamped_frames_total{venue="bybit",stream="bbo",symbol="BTCUSDT"} 2
    |}];
  return ()
;;

let%expect_test "norm pipe length gauge" =
  let t = Metrics.create ~now:(fun () -> time "2026-10-12T09:00:00Z") () in
  let key : Metrics.Key.t = { venue = Kraken; stream = L2; symbol = "BTC/USD" } in
  let r, w = Pipe.create () in
  Metrics.set_pipe_length t key (fun () -> Pipe.length r);
  Pipe.write_without_pushback w 1;
  Pipe.write_without_pushback w 2;
  Metrics.render t
  |> String.split_lines
  |> List.filter ~f:(String.is_prefix ~prefix:"market_recorder_norm_pipe")
  |> List.iter ~f:print_endline;
  [%expect
    {| market_recorder_norm_pipe_length{venue="kraken",stream="l2",symbol="BTC/USD"} 2 |}];
  return ()
;;
