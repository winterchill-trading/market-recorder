(* [Silence] over hand-made frame times. *)

open! Core
open Market_recorder

let start = Time_ns.of_string_with_utc_offset "2026-10-12T13:35:00Z"
let at ms = Time_ns.add start (Time_ns.Span.of_int_ms ms)

let run ?(threshold = Time_ns.Span.of_sec 2.) ~stop_ms times =
  let t = Silence.create ~threshold ~start () in
  List.iter times ~f:(fun ms -> Silence.add t (at ms));
  Silence.finish t ~stop:(at stop_ms);
  print_s
    [%message
      ""
        ~median:(Silence.median_interval t : Time_ns.Span.t option)
        ~ticks:(Silence.ticks t : bool)
        ~suspected:(Silence.suspected t : Silence.Gap.t list)]
;;

let%expect_test "a ticking stream that goes quiet" =
  (* every 100 ms for 3 s, nothing for 5 s, then again until 10 s *)
  run
    ~stop_ms:10_000
    (List.init 30 ~f:(fun i -> i * 100) @ List.init 20 ~f:(fun i -> 8_000 + (i * 100)));
  [%expect
    {|
    ((median (131.071ms)) (ticks true)
     (suspected
      (((from "2026-10-12 13:35:02.9Z") (until "2026-10-12 13:35:08Z")))))
    |}]
;;

let%expect_test "silence at the start and the end of the day counts" =
  run ~stop_ms:20_000 (List.init 50 ~f:(fun i -> 5_000 + (i * 50)));
  [%expect
    {|
    ((median (65.535ms)) (ticks true)
     (suspected
      (((from "2026-10-12 13:35:00Z") (until "2026-10-12 13:35:05Z"))
       ((from "2026-10-12 13:35:07.45Z") (until "2026-10-12 13:35:20Z")))))
    |}]
;;

let%expect_test "a quiet stream is not a gap" =
  run ~stop_ms:60_000 [ 1_000; 10_000; 30_000; 31_000 ];
  [%expect {| ((median (16.777215s)) (ticks false) (suspected ())) |}]
;;
