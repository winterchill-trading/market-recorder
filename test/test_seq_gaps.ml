(* [Seq_gaps] over hand-made sequences. *)

open! Core
open Market_recorder

let t0 = Time_ns.of_string_with_utc_offset "2026-10-12T13:35:00Z"
let at ms = Time_ns.add t0 (Time_ns.Span.of_int_ms ms)

let run checks =
  let t = Seq_gaps.create ~reorder:(Time_ns.Span.of_int_ms 100) () in
  List.iter checks ~f:(fun (ms, check) -> Seq_gaps.add t ~recv_ts:(at ms) check);
  Seq_gaps.flush t;
  List.iter (Seq_gaps.gaps t) ~f:(fun (g : Seq_gaps.Gap.t) ->
    printf
      "missing %d..%d before %s\n"
      g.first_missing
      g.last_missing
      (Time_ns.to_string_iso8601_basic g.at ~zone:Time_float.Zone.utc))
;;

let next n = Venue_seq.Chain { prev = n - 1; last = n }

let%expect_test "contiguous ids leave no gap, a jump lists the missing ids" =
  run [ 0, next 1; 10, next 2; 20, next 3 ];
  [%expect {| |}];
  run [ 0, next 1; 10, next 2; 500, next 6 ];
  [%expect {| missing 3..5 before 2026-10-12T13:35:00.500000000Z |}]
;;

let%expect_test "binance pu must equal the previous u" =
  run
    [ 0, Chain { prev = 90; last = 100 }
    ; 100, Chain { prev = 100; last = 120 }
    ; 200, Chain { prev = 130; last = 150 }
    ];
  [%expect {| missing 121..130 before 2026-10-12T13:35:00.200000000Z |}]
;;

let%expect_test "out of order within the reorder window is no gap" =
  run [ 0, next 1; 50, next 3; 60, next 2; 300, next 4 ];
  [%expect {| |}];
  (* once a later message has been applied, the late one comes too late *)
  run [ 0, next 1; 50, next 3; 300, next 4; 400, next 2 ];
  [%expect {| missing 2..2 before 2026-10-12T13:35:00.050000000Z |}]
;;

let%expect_test "duplicates are ignored, a restart starts over" =
  run [ 0, next 5; 10, next 5; 20, next 6; 30, Restart 1; 40, next 2; 50, next 4 ];
  [%expect {| missing 3..3 before 2026-10-12T13:35:00.050000000Z |}]
;;
