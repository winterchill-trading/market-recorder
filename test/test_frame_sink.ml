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
  let n = 1000 in
  let before = Gc.minor_words () in
  for i = 1 to n do
    Recorder.Frame_sink.on_raw sink ~stream:Bbo ~recv_ts:(at i) frame
  done;
  let words = Gc.minor_words () - before in
  printf "%.1f words per frame\n" (Float.of_int words /. Float.of_int n);
  [%expect {| 20.5 words per frame |}];
  Raw_writer.close raw
;;
