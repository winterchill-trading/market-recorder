(* Allocation of the recorder's per-frame path, pinned: minor words per frame through
   [Recorder.Frame_sink.on_raw] into an open raw minute file. *)

open! Core
open! Async
open Market_recorder
open Helpers

let frame =
  {|{"stream":"btcusdt@bookTicker","data":{"u":1,"b":"100000.10","a":"100000.20"}}|}
;;

let%expect_test "words per frame through on_raw" =
  let dir = temp_dir () in
  let raw = Raw_writer.create ~data_dir:dir ~on_closed:ignore () in
  let sink =
    Recorder.Frame_sink.create
      ~raw
      ~metrics:(Metrics.create ())
      ~warnings:(Warnings.create ())
      ~seen:(Hash_set.create (module Metrics.Key))
      ~venue:Binance
      ~symbol:"BTCUSDT"
  in
  let start = time "2026-10-12T09:15:00Z" in
  let at i = Time_ns.add start (Time_ns.Span.of_int_us (i * 37)) in
  Recorder.Frame_sink.on_raw sink ~stream:Bbo ~recv_ts:(at 0) frame;
  let%bind () = Raw_writer.flush raw in
  (* warm-up as in test_raw_line.ml: a one-off GC cost and buffer doublings *)
  for i = 1 to 2000 do
    Recorder.Frame_sink.on_raw sink ~stream:Bbo ~recv_ts:(at i) frame
  done;
  let n = 1000 in
  let before = Gc.minor_words () in
  for i = 2001 to 2000 + n do
    Recorder.Frame_sink.on_raw sink ~stream:Bbo ~recv_ts:(at i) frame
  done;
  let words = Gc.minor_words () - before in
  printf "%.1f words per frame\n" (Float.of_int words /. Float.of_int n);
  [%expect {| 0.0 words per frame |}];
  Raw_writer.close raw
;;

let%expect_test "a frame that goes back in time is written at the previous recv_ts" =
  let dir = temp_dir () in
  let closed = Queue.create () in
  let raw = Raw_writer.create ~data_dir:dir ~on_closed:(Queue.enqueue closed) () in
  let metrics = Metrics.create ~now:(fun () -> time "2026-10-12T09:15:00Z") () in
  let seen = Hash_set.create (module Metrics.Key) in
  let sink =
    Recorder.Frame_sink.create
      ~raw
      ~metrics
      ~warnings:(Warnings.create ~log:(fun _ -> print_endline "warned") ())
      ~seen
      ~venue:Bybit
      ~symbol:"BTCUSDT"
  in
  Recorder.Frame_sink.on_raw
    sink
    ~stream:Trades
    ~recv_ts:(time "2026-10-12T09:15:02Z")
    "a";
  Recorder.Frame_sink.on_raw
    sink
    ~stream:Trades
    ~recv_ts:(time "2026-10-12T09:15:01Z")
    "b";
  Recorder.Frame_sink.on_raw sink ~stream:L2 ~recv_ts:(time "2026-10-12T09:15:01Z") "c";
  print_s
    [%sexp
      (Hash_set.to_list seen |> List.sort ~compare:Metrics.Key.compare
       : Metrics.Key.t list)];
  print_s
    [%sexp
      (List.map (Metrics.streams metrics) ~f:(fun s -> s.key.stream, s.frames, s.clamped)
       : (Market_data.Stream.t * int * int) list)];
  let%bind () = Raw_writer.close raw in
  let%map contents =
    Queue.to_list closed
    |> List.sort ~compare:String.compare
    |> Deferred.List.map ~how:`Sequential ~f:unzstd
  in
  List.iter contents ~f:print_string;
  [%expect
    {|
    warned
    (((venue Bybit) (stream Trades) (symbol BTCUSDT))
     ((venue Bybit) (stream L2) (symbol BTCUSDT)))
    ((Trades 2 1) (L2 1 0))
    2026-10-12T09:15:01.000000Z c
    2026-10-12T09:15:02.000000Z a
    2026-10-12T09:15:02.000000Z b
    |}]
;;
