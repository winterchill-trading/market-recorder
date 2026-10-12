(* [Rebuild] over hand-written raw minute files of two venues. *)

open! Core
open! Async
open Market_recorder
module Md = Market_data

let date = Date.of_string "2026-10-12"

let hl_trade =
  {|{"channel":"trades","data":[{"coin":"BTC","side":"A","px":"82525.0","sz":"0.01671","time":1791812100812,"hash":"0x6b","tid":1,"users":["0x88","0xf5"]}]}|}
;;

let binance_trade =
  {|{"stream":"btcusdt@aggTrade","data":{"e":"aggTrade","E":1791817544988,"a":3482328964,"s":"BTCUSDT","p":"82613.60","q":"0.005","nq":"0.005","f":8165283112,"l":8165283113,"T":1791817544843,"m":false,"st":1}}|}
;;

let write_minute ~data_dir ~venue ~stream ~symbol lines =
  let dir = data_dir ^/ "raw" ^/ venue ^/ stream ^/ symbol ^/ "2026/10/12" in
  let%bind () = Unix.mkdir ~p:() dir in
  Writer.save
    (dir ^/ "13-35.ndjson")
    ~contents:(String.concat (List.map lines ~f:(fun l -> l ^ "\n")))
;;

let raw_day data_dir =
  let%bind () =
    write_minute
      ~data_dir
      ~venue:"hyperliquid"
      ~stream:"trades"
      ~symbol:"BTC"
      [ "2026-10-12T13:35:01.000000Z " ^ hl_trade
      ; ""
      ; "2026-10-12T13:35:02.000000Z " ^ hl_trade
      ]
  in
  write_minute
    ~data_dir
    ~venue:"binance"
    ~stream:"trades"
    ~symbol:"BTCUSDT"
    [ "2026-10-12T13:35:01.000000Z {\"result\":null,\"id\":1}"
    ; "2026-10-12T13:35:03.000000Z " ^ binance_trade
    ]
;;

let rebuild ?venues ?skip () =
  let dir = Helpers.temp_dir () in
  let data_dir = dir ^/ "data"
  and out_dir = dir ^/ "out" in
  let%bind () = raw_day data_dir in
  let%bind before = Helpers.tree data_dir in
  let%bind stats = Rebuild.run ?venues ?skip ~data_dir ~out_dir date in
  print_s [%sexp (stats : Md.Rebuild_norm.Stats.t Or_error.t)];
  let%bind after = Helpers.tree data_dir in
  if not ([%equal: string list] before after) then print_endline "data dir changed";
  Helpers.print_tree out_dir
;;

let%expect_test "every recorded venue has a normalizer" =
  print_s [%sexp (List.map Rebuild.normalizers ~f:Md.Normalizer.venue : Md.Venue.t list)];
  [%expect {| (Hyperliquid Binance Bybit Okx Coinbase Kraken Deribit Bitget) |}];
  return ()
;;

let%expect_test "rebuild a day of two venues" =
  let%bind () = rebuild () in
  [%expect
    {|
    (Ok
     ((files 2) (frames 4) (disconnects 1) (events 3) (frame_errors 0)
      (first_errors ()) (skipped_files 0) (skipped_venues ())))
    binance/BTCUSDT/norm/trades/2026-10-12.bin
    hyperliquid/BTC/norm/trades/2026-10-12.bin
    |}];
  return ()
;;

let%expect_test "-venue keeps one venue" =
  let%bind () = rebuild ~venues:[ Binance ] () in
  [%expect
    {|
    (Ok
     ((files 2) (frames 2) (disconnects 0) (events 1) (frame_errors 0)
      (first_errors ()) (skipped_files 1) (skipped_venues (Hyperliquid))))
    binance/BTCUSDT/norm/trades/2026-10-12.bin
    |}];
  return ()
;;

let%expect_test "-skip leaves a raw stream out" =
  let%bind () = rebuild ~skip:[ { venue = Hyperliquid; stream = Trades } ] () in
  [%expect
    {|
    (Ok
     ((files 1) (frames 2) (disconnects 0) (events 1) (frame_errors 0)
      (first_errors ()) (skipped_files 0) (skipped_venues ())))
    binance/BTCUSDT/norm/trades/2026-10-12.bin
    |}];
  return ()
;;

let%expect_test "skip parsing" =
  List.iter
    [ "binance:l2"; "Hyperliquid:BBO"; "binance"; "binance:depth"; "nasdaq:l2" ]
    ~f:(fun s -> print_s [%sexp (Rebuild.Skip.of_string s : Rebuild.Skip.t Or_error.t)]);
  [%expect
    {|
    (Ok ((venue Binance) (stream L2)))
    (Ok ((venue Hyperliquid) (stream Bbo)))
    (Error ("expected venue:stream" binance))
    (Error ("unknown venue or stream" binance:depth))
    (Error ("unknown venue or stream" nasdaq:l2))
    |}];
  return ()
;;

let%expect_test "-collector reads one collector's files" =
  let dir = Helpers.temp_dir () in
  let data_dir = dir ^/ "data" in
  let%bind () = raw_day data_dir in
  let day = "2026/10/12" in
  let hl = data_dir ^/ "raw/hyperliquid/trades/BTC" ^/ day in
  let%bind () =
    Unix.rename ~src:(hl ^/ "13-35.ndjson") ~dst:(hl ^/ "13-35.east.ndjson")
  in
  let%bind before = Helpers.tree data_dir in
  let run ?collector out =
    let%bind stats = Rebuild.run ?collector ~data_dir ~out_dir:(dir ^/ out) date in
    print_s [%sexp (stats : Md.Rebuild_norm.Stats.t Or_error.t)];
    Helpers.print_tree (dir ^/ out)
  in
  let%bind () = run ~collector:"east" "east" in
  [%expect
    {|
    (Ok
     ((files 1) (frames 2) (disconnects 1) (events 2) (frame_errors 0)
      (first_errors ()) (skipped_files 0) (skipped_venues ())))
    hyperliquid/BTC/norm/trades/2026-10-12.bin
    |}];
  let%bind () = run "plain" in
  [%expect
    {|
    (Ok
     ((files 1) (frames 2) (disconnects 0) (events 1) (frame_errors 0)
      (first_errors ()) (skipped_files 0) (skipped_venues ())))
    binance/BTCUSDT/norm/trades/2026-10-12.bin
    |}];
  let%bind after = Helpers.tree data_dir in
  print_s [%sexp ([%equal: string list] before after : bool)];
  [%expect {| true |}];
  return ()
;;
