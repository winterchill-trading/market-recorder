(* [Clock_error] over recorded [chronyc -c tracking] output and stand-in commands. *)

open! Core
open! Async
open Market_recorder

let tracking =
  "A9FEA97B,169.254.169.123,4,1791817544.123456789,0.000012345,0.000003000,0.000020000,-3.100,0.001,0.020,0.000400000,0.000150000,64.2,Normal"
;;

let%expect_test "bound from a tracking line" =
  print_s [%sexp (Clock_error.parse_tracking tracking : Time_ns.Span.t Or_error.t)];
  print_s [%sexp (Clock_error.parse_tracking "506" : Time_ns.Span.t Or_error.t)];
  [%expect
    {|
    (Ok 362.345us)
    (Error ("chronyc tracking: expected 14 fields" 506))
    |}];
  return ()
;;

let%expect_test "gauge from a command, absent without chrony" =
  let show t =
    let%map () = Clock_error.ready t in
    let metrics = Metrics.create () in
    Clock_error.register t metrics;
    Clock_error.stop t;
    Metrics.render metrics
    |> String.split_lines
    |> List.filter ~f:(String.is_substring ~substring:"clock_error")
    |> List.iter ~f:print_endline
  in
  let%bind () = show (Clock_error.start ~command:("echo", [ tracking ]) ()) in
  [%expect
    {|
    # HELP market_recorder_clock_error_seconds Clock error bound from chronyc tracking: |offset| + root delay / 2 + root dispersion.
    # TYPE market_recorder_clock_error_seconds gauge
    market_recorder_clock_error_seconds 0.000362345
    |}];
  Log.Global.set_output [];
  let%bind () =
    show (Clock_error.start ~command:("/nonexistent/chronyc", [ "-c"; "tracking" ]) ())
  in
  [%expect {| |}];
  return ()
;;
