(* [Venue_seq] over frames as the venues send them. *)

open! Core
open Market_recorder

let show venue stream frame =
  print_s [%sexp (Venue_seq.of_frame ~venue ~stream frame : Venue_seq.t)]
;;

let%expect_test "binance depth updates chain pu to u" =
  show
    Binance
    L2
    {|{"stream":"btcusdt@depth@100ms","data":{"e":"depthUpdate","E":1,"T":1,"s":"BTCUSDT","U":11,"u":15,"pu":10,"b":[],"a":[["1","2"]]}}|};
  [%expect {| ((identity (u:15)) (check ((Chain (prev 10) (last 15))))) |}];
  show Binance L2 {|{"lastUpdateId":15,"E":1,"T":1,"bids":[],"asks":[]}|};
  [%expect {| ((identity ()) (check ())) |}]
;;

let%expect_test "binance aggregate trades are contiguous" =
  show
    Binance
    Trades
    {|{"stream":"btcusdt@aggTrade","data":{"e":"aggTrade","E":1,"a":3482328964,"s":"BTCUSDT","p":"1","q":"1","f":1,"l":2,"T":1,"m":false}}|};
  [%expect
    {|
    ((identity (a:3482328964))
     (check ((Chain (prev 3482328963) (last 3482328964)))))
    |}]
;;

let%expect_test "bybit book deltas, snapshots and restarts" =
  let frame typ u =
    sprintf
      {|{"topic":"orderbook.50.BTCUSDT","type":"%s","ts":1,"data":{"s":"BTCUSDT","b":[],"a":[["1","1"]],"u":%d,"seq":99},"cts":1}|}
      typ
      u
  in
  show Bybit L2 (frame "delta" 7);
  [%expect {| ((identity (delta:7)) (check ((Chain (prev 6) (last 7))))) |}];
  show Bybit L2 (frame "snapshot" 7);
  [%expect {| ((identity (snapshot:7)) (check ())) |}];
  show Bybit L2 (frame "snapshot" 1);
  [%expect {| ((identity (snapshot:1)) (check ((Restart 1)))) |}]
;;

let%expect_test "venues and streams without a sequence" =
  show Hyperliquid L2 {|{"channel":"l2Book","data":{"coin":"BTC","time":1,"levels":[]}}|};
  show Bybit Trades {|{"topic":"publicTrade.BTCUSDT","data":[{"i":"5","seq":3}]}|};
  show Binance L2 {|{"result":null,"id":1}|};
  [%expect
    {|
    ((identity ()) (check ()))
    ((identity ()) (check ()))
    ((identity ()) (check ()))
    |}]
;;

let%expect_test "field_int" =
  let f key s = print_s [%sexp (Venue_seq.field_int s ~key : int option)] in
  f "u" {|{"U":1,"u": 22}|};
  f "i" {|{"i":"5"}|};
  f "u" {|{"u":"x"}|};
  f "u" {|{"a":1}|};
  [%expect {|
    (22)
    (5)
    ()
    ()
    |}]
;;
