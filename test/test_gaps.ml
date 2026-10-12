(* [Recorder.record_gaps] over a stand-in feed that reports a reconnect. *)

open! Core
open! Async
open Market_recorder
open Helpers

let%expect_test "a reported gap writes a disconnect line and is counted" =
  let dir = temp_dir () in
  let raw = Raw_writer.create ~data_dir:dir ~on_closed:ignore () in
  let metrics = Metrics.create () in
  let streams : Market_data.Stream.t list = [ Trades; Bbo; L2 ] in
  let key stream = { Metrics.Key.venue = Binance; stream; symbol = "BTCUSDT" } in
  List.iter streams ~f:(fun s -> Metrics.register metrics (key s));
  let write stream ts frame =
    Raw_writer.write raw ~venue:Binance ~stream ~symbol:"BTCUSDT" ~recv_ts:(time ts) frame
  in
  (* no L2 frame yet: its file is not open, so it gets no line *)
  write Trades "2026-10-12T13:35:01Z" "t1";
  write Bbo "2026-10-12T13:35:01Z" "b1";
  let gaps_r, gaps_w = Pipe.create () in
  let opened = Hash_set.of_list (module Metrics.Key) [ key Trades; key Bbo ] in
  let recording =
    Recorder.record_gaps
      ~raw
      ~metrics
      ~is_open:(Hash_set.mem opened)
      ~venue:Binance
      ~symbol:"BTCUSDT"
      ~streams
      gaps_r
  in
  let gap ?instrument ?stream ts =
    Pipe.write_without_pushback
      gaps_w
      { Market_data.Gap.recv_ts = time ts
      ; venue = Binance
      ; instrument
      ; stream
      ; reason = Resync
      }
  in
  (* a reconnect of the whole connection, then a book resync of another symbol *)
  gap "2026-10-12T13:35:02Z";
  gap
    ~instrument:(Market_data.Instrument.create Binance "ETHUSDT")
    ~stream:L2
    "2026-10-12T13:35:02.5Z";
  Pipe.close gaps_w;
  let%bind () = recording in
  write Trades "2026-10-12T13:35:03Z" "t3";
  let%bind () = Raw_writer.close raw in
  let%bind () =
    Deferred.List.iter ~how:`Sequential [ "trades"; "bbo" ] ~f:(fun stream ->
      let%map text =
        unzstd (dir ^/ "raw/binance" ^/ stream ^/ "BTCUSDT/2026/10/12/13-35.ndjson.zst")
      in
      printf "== %s\n%s" stream text)
  in
  Metrics.render metrics
  |> String.split_lines
  |> List.filter ~f:(String.is_prefix ~prefix:"market_recorder_gaps_total")
  |> List.iter ~f:print_endline;
  [%expect
    {|
    == trades
    2026-10-12T13:35:01.000000Z t1

    2026-10-12T13:35:03.000000Z t3
    == bbo
    2026-10-12T13:35:01.000000Z b1

    market_recorder_gaps_total{venue="binance",stream="trades",symbol="BTCUSDT"} 1
    market_recorder_gaps_total{venue="binance",stream="bbo",symbol="BTCUSDT"} 1
    market_recorder_gaps_total{venue="binance",stream="l2",symbol="BTCUSDT"} 1
    |}];
  return ()
;;

let%expect_test "a per-instrument gap writes a line only into that symbol's open files" =
  let dir = temp_dir () in
  let raw = Raw_writer.create ~data_dir:dir ~on_closed:ignore () in
  let metrics = Metrics.create () in
  let streams : Market_data.Stream.t list = [ Trades; L2 ] in
  let symbols = [ "BTC-USDT"; "ETH-USDT" ] in
  let key symbol stream = { Metrics.Key.venue = Okx; stream; symbol } in
  List.iter symbols ~f:(fun symbol ->
    List.iter streams ~f:(fun s -> Metrics.register metrics (key symbol s)));
  let write symbol stream ts frame =
    Raw_writer.write raw ~venue:Okx ~stream ~symbol ~recv_ts:(time ts) frame
  in
  List.iter symbols ~f:(fun symbol ->
    write symbol Trades "2026-10-12T13:35:01Z" "t1";
    write symbol L2 "2026-10-12T13:35:01Z" "l1");
  let opened =
    Hash_set.of_list
      (module Metrics.Key)
      (List.concat_map symbols ~f:(fun symbol -> List.map streams ~f:(key symbol)))
  in
  (* one recorder feed per symbol, each seeing the connection's gaps *)
  let writers, recordings =
    List.map symbols ~f:(fun symbol ->
      let r, w = Pipe.create () in
      ( w
      , Recorder.record_gaps
          ~raw
          ~metrics
          ~is_open:(Hash_set.mem opened)
          ~venue:Okx
          ~symbol
          ~streams
          r ))
    |> List.unzip
  in
  (* the ETH-USDT book resyncs after a sequence break *)
  List.iter writers ~f:(fun w ->
    Pipe.write_without_pushback
      w
      { Market_data.Gap.recv_ts = time "2026-10-12T13:35:02Z"
      ; venue = Okx
      ; instrument = Some (Market_data.Instrument.create Okx "ETH-USDT")
      ; stream = Some L2
      ; reason = Resync
      };
    Pipe.close w);
  let%bind () = Deferred.all_unit recordings in
  List.iter symbols ~f:(fun symbol -> write symbol L2 "2026-10-12T13:35:03Z" "l3");
  let%bind () = Raw_writer.close raw in
  let%bind () =
    Deferred.List.iter ~how:`Sequential symbols ~f:(fun symbol ->
      Deferred.List.iter ~how:`Sequential [ "trades"; "l2" ] ~f:(fun stream ->
        let%map text =
          unzstd (dir ^/ "raw/okx" ^/ stream ^/ symbol ^/ "2026/10/12/13-35.ndjson.zst")
        in
        printf "== %s %s\n%s" symbol stream text))
  in
  Metrics.render metrics
  |> String.split_lines
  |> List.filter ~f:(String.is_prefix ~prefix:"market_recorder_gaps_total")
  |> List.iter ~f:print_endline;
  [%expect
    {|
    == BTC-USDT trades
    2026-10-12T13:35:01.000000Z t1
    == BTC-USDT l2
    2026-10-12T13:35:01.000000Z l1
    2026-10-12T13:35:03.000000Z l3
    == ETH-USDT trades
    2026-10-12T13:35:01.000000Z t1
    == ETH-USDT l2
    2026-10-12T13:35:01.000000Z l1

    2026-10-12T13:35:03.000000Z l3
    market_recorder_gaps_total{venue="okx",stream="trades",symbol="BTC-USDT"} 0
    market_recorder_gaps_total{venue="okx",stream="trades",symbol="ETH-USDT"} 0
    market_recorder_gaps_total{venue="okx",stream="l2",symbol="BTC-USDT"} 0
    market_recorder_gaps_total{venue="okx",stream="l2",symbol="ETH-USDT"} 1
    |}];
  return ()
;;
