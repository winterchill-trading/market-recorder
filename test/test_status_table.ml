open! Core
open! Async
open Market_recorder
open Helpers

let%expect_test "metrics text as tables" =
  let now = ref (time "2026-10-12T09:00:00Z") in
  let t = Metrics.create ~now:(fun () -> !now) () in
  let k venue stream symbol : Metrics.Key.t = { venue; stream; symbol } in
  let a = k Binance Trades "BTCUSDT" in
  let b = k Kraken L2 "BTC/USD" in
  Metrics.register t a;
  Metrics.register t b;
  Metrics.frame t a ~recv_ts:!now ~bytes:1234;
  Metrics.event t a;
  now := time "2026-10-12T09:00:03.5Z";
  Metrics.set_upload_source t (fun () -> 12, 0, 1);
  let text =
    Metrics.render t ^ {|market_recorder_build_info{version="abc",ocaml="5.2.0"} 1|}
  in
  (match Status_table.parse text with
   | Error e -> print_s [%sexp (e : Error.t)]
   | Ok samples -> print_string (Status_table.render samples));
  [%expect
    {|
    venue    stream  symbol   frames  bytes  events  clamped_frames  gaps  norm_pipe_length  healthz_flaps  last_frame_age_seconds
    binance  trades  BTCUSDT       1   1234       1               0     0                 0              0                   3.500
    kraken   l2      BTC/USD       0      0       0               0     0                 0              0                   3.500

    uploads                              12
    upload_failures                      0
    upload_pending                       1
    build_info{version=abc,ocaml=5.2.0}  1
    |}];
  return ()
;;

let%expect_test "parse errors name the line" =
  print_s
    [%sexp
      (Status_table.parse "ok 1\nbroken{a=1} 2\n" |> Or_error.map ~f:List.length
       : int Or_error.t)];
  [%expect {| (Error ("broken{a=1} 2" "label value not quoted")) |}];
  print_s
    [%sexp
      (Status_table.parse {|x{a="q\"z",b="2"} 3.5|}
       : Status_table.Sample.t list Or_error.t)];
  [%expect {| (Ok (((name x) (labels ((a "q\"z") (b 2))) (value 3.5)))) |}];
  return ()
;;
