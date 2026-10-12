(* [Cycle_monitor] with a stand-in clock and a real blocked cycle. *)

open! Core
open! Async
open Market_recorder

let%expect_test "count over 50ms, warn over 20ms at most every 10s" =
  let now = ref (Time_ns.of_string_with_utc_offset "2026-10-12T10:00:00Z") in
  let t = Cycle_monitor.create ~now:(fun () -> !now) ~warn:print_s () in
  let cycle ms = Cycle_monitor.observe t (Time_ns.Span.of_int_ms ms) in
  cycle 5;
  cycle 30;
  cycle 60;
  cycle 80;
  now := Time_ns.add !now (Time_ns.Span.of_sec 11.);
  cycle 25;
  print_s
    [%message
      ""
        ~long_cycles:(Cycle_monitor.long_cycles t : int)
        ~longest:(Cycle_monitor.longest t : Time_ns.Span.t)];
  [%expect
    {|
    ("long async cycle" (cycle 30ms) (suppressed_since_last_warning 0))
    ("long async cycle" (cycle 25ms) (suppressed_since_last_warning 2))
    ((long_cycles 2) (longest 80ms))
    |}];
  return ()
;;

let%expect_test "a blocked scheduler is seen" =
  let t = Cycle_monitor.create ~warn:ignore () in
  Cycle_monitor.start t;
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 1) in
  Time_ns_unix.pause (Time_ns.Span.of_int_ms 70);
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 20) in
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 20) in
  let metrics = Metrics.create () in
  Cycle_monitor.register t metrics;
  print_s [%sexp (Cycle_monitor.long_cycles t >= 1 : bool)];
  [%expect {| true |}];
  return ()
;;
