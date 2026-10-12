open! Core
open! Async
open Market_data
open Helpers

let btc = Instrument.create Binance "BTCUSDT"

let trade ~ts:s ~id : Event.t =
  Trade
    { instrument = btc
    ; exch_ts = time s
    ; recv_ts = time s
    ; price = Price.of_string "100.5"
    ; size = Size.of_string "0.25"
    ; side = Buy
    ; trade_id = id
    }
;;

let bbo ~ts:s : Event.t =
  Bbo
    { instrument = btc
    ; exch_ts = time s
    ; recv_ts = time s
    ; bid_price = Price.of_int 100
    ; bid_size = Size.one
    ; ask_price = Price.of_int 101
    ; ask_size = Size.one
    }
;;

let%expect_test "a feed is drained into daily event logs" =
  let dir = temp_dir () in
  let t = Market_recorder.Norm_writer.create ~data_dir:dir () in
  let events =
    [ trade ~ts:"2026-10-12T23:59:59Z" ~id:"1"
    ; bbo ~ts:"2026-10-12T23:59:59.5Z"
    ; trade ~ts:"2026-10-13T00:00:01Z" ~id:"2"
    ]
  in
  let feed = Replay_feed.of_events ~speed:0. (Pipe.of_list events) in
  let seen = ref 0 in
  let%bind () =
    Market_recorder.Norm_writer.consume t feed ~on_event:(fun _ -> incr seen)
  in
  let%bind () = Market_recorder.Norm_writer.close t in
  print_s [%sexp (!seen : int)];
  [%expect {| 3 |}];
  let%bind () = print_tree dir in
  [%expect
    {|
    binance/BTCUSDT/norm/bbo/2026-10-12.bin
    binance/BTCUSDT/norm/trades/2026-10-12.bin
    binance/BTCUSDT/norm/trades/2026-10-13.bin
    |}];
  let%bind back, tail =
    Event_log.load_file (dir ^/ "binance/BTCUSDT/norm/trades/2026-10-12.bin")
  in
  print_s [%sexp (List.length back : int), (tail : Framed.Tail.t)];
  [%expect {| (1 Clean) |}];
  return ()
;;
