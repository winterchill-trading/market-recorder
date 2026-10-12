open! Core
open! Async
open Market_recorder
open Helpers

let%expect_test "one line a minute per stream, with the suppressed count" =
  let now = ref (time "2026-10-12T09:00:00Z") in
  let t = Warnings.create ~now:(fun () -> !now) ~log:print_s () in
  let a : Metrics.Key.t = { venue = Bybit; stream = L2; symbol = "BTCUSDT" } in
  let b : Metrics.Key.t = { venue = Okx; stream = Trades; symbol = "BTC-USDT" } in
  let at s key =
    now := time s;
    Warnings.warn t key [%message "recv_ts went backwards"]
  in
  at "2026-10-12T09:00:00Z" a;
  at "2026-10-12T09:00:01Z" a;
  at "2026-10-12T09:00:02Z" b;
  at "2026-10-12T09:00:30Z" a;
  [%expect
    {|
    ("recv_ts went backwards"
     (stream ((venue Bybit) (stream L2) (symbol BTCUSDT))))
    ("recv_ts went backwards"
     (stream ((venue Okx) (stream Trades) (symbol BTC-USDT))))
    |}];
  print_s [%sexp (Warnings.suppressed t : int)];
  [%expect {| 2 |}];
  at "2026-10-12T09:01:00Z" a;
  at "2026-10-12T09:01:01Z" a;
  [%expect
    {|
    ("recv_ts went backwards"
     (stream ((venue Bybit) (stream L2) (symbol BTCUSDT))) (suppressed 2))
    |}];
  return ()
;;
