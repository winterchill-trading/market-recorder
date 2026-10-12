(* [Raw_merge] over hand-written minutes of two collectors. *)

open! Core
open! Async
open Market_recorder
module Line = Market_data.Raw_minute.Line

let minute = Helpers.time "2026-10-12T13:35:00Z"
let window = Time_ns.Span.of_sec 5.
let lines l = List.map l ~f:(fun s -> Line.parse s |> Or_error.ok_exn)
let frame sec text = sprintf "2026-10-12T13:35:%sZ %s" sec text

let print_lines l =
  List.iter l ~f:(fun (line : Line.t) ->
    match line with
    | Disconnect -> print_endline "<disconnect>"
    | Frame { recv_ts; payload } ->
      printf "%s %s\n" (Raw_writer.format_ts recv_ts) payload)
;;

let merge ?identity ?clock_error ?(carry = Raw_merge.Carry.empty) ?(minute = minute) a b =
  let lines, counts, carry =
    Raw_merge.merge_minute
      ?identity
      ?clock_error
      ~window
      ~minute
      carry
      ~a:(Option.map a ~f:lines)
      ~b:(Option.map b ~f:lines)
  in
  print_lines lines;
  print_s [%sexp (counts : Raw_merge.Counts.t)];
  carry
;;

let%expect_test "earliest copy of each frame wins" =
  let (_ : Raw_merge.Carry.t) =
    merge
      (Some [ frame "01.000100" "x1"; frame "02.000000" "x2"; frame "04.000000" "x4" ])
      (Some [ frame "01.000050" "x1"; frame "02.000300" "x2"; frame "03.000000" "x3" ])
  in
  [%expect
    {|
    2026-10-12T13:35:01.000050Z x1
    2026-10-12T13:35:02.000000Z x2
    2026-10-12T13:35:03.000000Z x3
    2026-10-12T13:35:04.000000Z x4
    ((minutes 1) (only_a 1) (only_b 1) (both 2) (gaps_closed 0) (gaps_kept 0)
     (text_differs 0) (previous_day 0))
    |}];
  return ()
;;

let%expect_test "repeated frames pair up in time order, outside the window stay apart" =
  let (_ : Raw_merge.Carry.t) =
    merge
      (Some
         [ frame "01.000000" "same"; frame "02.000000" "same"; frame "30.000000" "same" ])
      (Some
         [ frame "01.000010" "same"; frame "02.000010" "same"; frame "40.000000" "same" ])
  in
  [%expect
    {|
    2026-10-12T13:35:01.000000Z same
    2026-10-12T13:35:02.000000Z same
    2026-10-12T13:35:30.000000Z same
    2026-10-12T13:35:40.000000Z same
    ((minutes 1) (only_a 1) (only_b 1) (both 2) (gaps_closed 0) (gaps_kept 0)
     (text_differs 0) (previous_day 0))
    |}];
  return ()
;;

let%expect_test "a disconnect the other copy covered is dropped" =
  let (_ : Raw_merge.Carry.t) =
    merge
      (Some [ frame "01.000000" "x1"; ""; frame "09.000000" "x9" ])
      (Some [ frame "01.000001" "x1"; frame "05.000000" "x5"; frame "09.000001" "x9" ])
  in
  [%expect
    {|
    2026-10-12T13:35:01.000000Z x1
    2026-10-12T13:35:05.000000Z x5
    2026-10-12T13:35:09.000000Z x9
    ((minutes 1) (only_a 0) (only_b 1) (both 2) (gaps_closed 1) (gaps_kept 0)
     (text_differs 0) (previous_day 0))
    |}];
  return ()
;;

let%expect_test "overlapping disconnects stay as one gap" =
  let (_ : Raw_merge.Carry.t) =
    merge
      (Some [ frame "01.000000" "x1"; ""; frame "09.000000" "x9" ])
      (Some
         [ frame "01.000001" "x1"; frame "03.000000" "x3"; ""; frame "20.000000" "x20" ])
  in
  [%expect
    {|
    2026-10-12T13:35:01.000000Z x1
    <disconnect>
    2026-10-12T13:35:03.000000Z x3
    2026-10-12T13:35:09.000000Z x9
    2026-10-12T13:35:20.000000Z x20
    ((minutes 1) (only_a 1) (only_b 2) (both 1) (gaps_closed 1) (gaps_kept 1)
     (text_differs 0) (previous_day 0))
    |}];
  return ()
;;

let%expect_test "a missing file is a gap over the whole minute" =
  let (_ : Raw_merge.Carry.t) =
    merge (Some [ frame "01.000000" "x1"; ""; frame "09.000000" "x9" ]) None
  in
  [%expect
    {|
    2026-10-12T13:35:01.000000Z x1
    <disconnect>
    2026-10-12T13:35:09.000000Z x9
    ((minutes 1) (only_a 2) (only_b 0) (both 0) (gaps_closed 0) (gaps_kept 1)
     (text_differs 0) (previous_day 0))
    |}];
  let (_ : Raw_merge.Carry.t) = merge None (Some [ ""; frame "09.000000" "x9" ]) in
  [%expect
    {|
    <disconnect>
    2026-10-12T13:35:09.000000Z x9
    ((minutes 1) (only_a 0) (only_b 1) (both 0) (gaps_closed 0) (gaps_kept 1)
     (text_differs 0) (previous_day 0))
    |}];
  return ()
;;

let%expect_test "a frame stamped on both sides of a minute boundary is kept once" =
  let carry =
    merge (Some [ frame "59.999000" "edge" ]) (Some [ frame "30.000000" "early" ])
  in
  [%expect
    {|
    2026-10-12T13:35:30.000000Z early
    2026-10-12T13:35:59.999000Z edge
    ((minutes 1) (only_a 1) (only_b 1) (both 0) (gaps_closed 0) (gaps_kept 0)
     (text_differs 0) (previous_day 0))
    |}];
  let (_ : Raw_merge.Carry.t) =
    merge
      ~carry
      ~minute:(Helpers.time "2026-10-12T13:36:00Z")
      (Some [ "2026-10-12T13:36:01.000000Z next" ])
      (Some [ "2026-10-12T13:36:00.001000Z edge"; "2026-10-12T13:36:01.000002Z next" ])
  in
  [%expect
    {|
    2026-10-12T13:36:01.000000Z next
    ((minutes 1) (only_a -1) (only_b 0) (both 2) (gaps_closed 0) (gaps_kept 0)
     (text_differs 0) (previous_day 0))
    |}];
  return ()
;;

let%expect_test "frames with the same venue sequence are one message" =
  let depth ~e ~u =
    sprintf
      {|{"stream":"btcusdt@depth@100ms","data":{"e":"depthUpdate","E":%d,"T":1,"s":"BTCUSDT","U":%d,"u":%d,"pu":%d,"b":[],"a":[]}}|}
      e
      u
      u
      (u - 1)
  in
  let identity payload =
    (Venue_seq.of_frame ~venue:Binance ~stream:L2 payload).identity
  in
  (* the same update with a different event time on the two connections *)
  let (_ : Raw_merge.Carry.t) =
    merge
      ~identity
      (Some [ frame "01.000000" (depth ~e:1 ~u:7); frame "02.000000" (depth ~e:2 ~u:8) ])
      (Some [ frame "01.000100" (depth ~e:9 ~u:7); frame "03.000000" (depth ~e:3 ~u:9) ])
  in
  [%expect
    {|
    2026-10-12T13:35:01.000000Z {"stream":"btcusdt@depth@100ms","data":{"e":"depthUpdate","E":1,"T":1,"s":"BTCUSDT","U":7,"u":7,"pu":6,"b":[],"a":[]}}
    2026-10-12T13:35:02.000000Z {"stream":"btcusdt@depth@100ms","data":{"e":"depthUpdate","E":2,"T":1,"s":"BTCUSDT","U":8,"u":8,"pu":7,"b":[],"a":[]}}
    2026-10-12T13:35:03.000000Z {"stream":"btcusdt@depth@100ms","data":{"e":"depthUpdate","E":3,"T":1,"s":"BTCUSDT","U":9,"u":9,"pu":8,"b":[],"a":[]}}
    ((minutes 1) (only_a 1) (only_b 1) (both 1) (gaps_closed 0) (gaps_kept 0)
     (text_differs 1) (previous_day 0))
    |}];
  return ()
;;

let%expect_test "the clock bound widens the window and stops ordering close copies" =
  let a = Some [ frame "01.000000" "x1"; frame "10.000000" "x2" ]
  and b = Some [ frame "00.999000" "x1"; frame "15.500000" "x2" ] in
  (* without a bound: B's earlier x1 wins, x2 is 5.5 s apart and stays twice *)
  let (_ : Raw_merge.Carry.t) = merge a b in
  [%expect
    {|
    2026-10-12T13:35:00.999000Z x1
    2026-10-12T13:35:10.000000Z x2
    2026-10-12T13:35:15.500000Z x2
    ((minutes 1) (only_a 1) (only_b 1) (both 1) (gaps_closed 0) (gaps_kept 0)
     (text_differs 0) (previous_day 0))
    |}];
  let (_ : Raw_merge.Carry.t) = merge ~clock_error:(Time_ns.Span.of_sec 1.) a b in
  [%expect
    {|
    2026-10-12T13:35:01.000000Z x1
    2026-10-12T13:35:10.000000Z x2
    ((minutes 1) (only_a 0) (only_b 0) (both 2) (gaps_closed 0) (gaps_kept 0)
     (text_differs 0) (previous_day 0))
    |}];
  return ()
;;

let write_minute ~data_dir ~venue ~stream ~symbol ~name lines =
  let dir = data_dir ^/ "raw" ^/ venue ^/ stream ^/ symbol ^/ "2026/10/12" in
  let%bind () = Unix.mkdir ~p:() dir in
  Writer.save
    (dir ^/ name ^ ".ndjson")
    ~contents:(String.concat (List.map lines ~f:(fun l -> l ^ "\n")))
;;

let at hm sec text = sprintf "2026-10-12T13:%s:%sZ %s" hm sec text

let two_collectors dir =
  let a = dir ^/ "a"
  and b = dir ^/ "b" in
  let%bind () =
    write_minute
      ~data_dir:a
      ~venue:"binance"
      ~stream:"trades"
      ~symbol:"BTCUSDT"
      ~name:"13-35"
      [ at "35" "01.000000" "t1"; ""; at "35" "40.000000" "t4" ]
  in
  let%bind () =
    write_minute
      ~data_dir:b
      ~venue:"binance"
      ~stream:"trades"
      ~symbol:"BTCUSDT"
      ~name:"13-35"
      [ at "35" "01.000200" "t1"
      ; at "35" "10.000000" "t2"
      ; at "35" "20.000000" "t3"
      ; at "35" "40.000100" "t4"
      ]
  in
  (* collector A was down for 13:36 *)
  let%bind () =
    write_minute
      ~data_dir:b
      ~venue:"binance"
      ~stream:"trades"
      ~symbol:"BTCUSDT"
      ~name:"13-36"
      [ at "36" "05.000000" "t5" ]
  in
  let%bind () =
    write_minute
      ~data_dir:a
      ~venue:"hyperliquid"
      ~stream:"l2"
      ~symbol:"BTC"
      ~name:"13-35"
      [ at "35" "02.000000" "b1" ]
  in
  let%bind () =
    write_minute
      ~data_dir:b
      ~venue:"hyperliquid"
      ~stream:"l2"
      ~symbol:"BTC"
      ~name:"13-35"
      [ at "35" "02.000000" "b1" ]
  in
  (* compress A's binance minute the way the recorder does *)
  let%map (_ : string) =
    Raw_writer.compress_file (a ^/ "raw/binance/trades/BTCUSDT/2026/10/12/13-35.ndjson")
  in
  a, b
;;

let%expect_test "merge a day of two collectors" =
  let dir = Helpers.temp_dir () in
  let%bind a_dir, b_dir = two_collectors dir in
  let out_dir = dir ^/ "out" in
  let date = Date.of_string "2026-10-12" in
  let%bind report = Raw_merge.run ~a_dir ~b_dir ~out_dir date in
  print_s
    [%sexp
      (Or_error.map report ~f:(fun r -> r.series)
       : (Raw_merge.Series.t * Raw_merge.Counts.t) list Or_error.t)];
  [%expect
    {|
    (Ok
     ((((venue Hyperliquid) (stream L2) (symbol_dir BTC))
       ((minutes 1) (only_a 0) (only_b 0) (both 1) (gaps_closed 0) (gaps_kept 0)
        (text_differs 0) (previous_day 0)))
      (((venue Binance) (stream Trades) (symbol_dir BTCUSDT))
       ((minutes 2) (only_a 0) (only_b 3) (both 2) (gaps_closed 1) (gaps_kept 0)
        (text_differs 0) (previous_day 0)))))
    |}];
  let%bind () = Helpers.print_tree out_dir in
  [%expect
    {|
    _merge/2026-10-12.json
    raw/binance/trades/BTCUSDT/2026/10/12/13-35.ndjson.zst
    raw/binance/trades/BTCUSDT/2026/10/12/13-36.ndjson.zst
    raw/hyperliquid/l2/BTC/2026/10/12/13-35.ndjson.zst
    |}];
  let%bind merged =
    Helpers.unzstd (out_dir ^/ "raw/binance/trades/BTCUSDT/2026/10/12/13-35.ndjson.zst")
  in
  print_string merged;
  [%expect
    {|
    2026-10-12T13:35:01.000000Z t1
    2026-10-12T13:35:10.000000Z t2
    2026-10-12T13:35:20.000000Z t3
    2026-10-12T13:35:40.000000Z t4
    |}];
  let%bind json = Reader.file_contents (out_dir ^/ "_merge/2026-10-12.json") in
  print_string json;
  [%expect
    {|
    {
      "date": "2026-10-12",
      "window_ms": 5000,
      "clock_error_ms": 0,
      "total": {"minutes": 3, "only_a": 0, "only_b": 3, "both": 3, "gaps_closed": 1, "gaps_kept": 0, "text_differs": 0, "previous_day": 0},
      "series": [
        {"venue": "hyperliquid", "stream": "l2", "symbol": "BTC", "minutes": 1, "only_a": 0, "only_b": 0, "both": 1, "gaps_closed": 0, "gaps_kept": 0, "text_differs": 0, "previous_day": 0, "median_interval_ms": null, "suspected_gaps": []},
        {"venue": "binance", "stream": "trades", "symbol": "BTCUSDT", "minutes": 2, "only_a": 0, "only_b": 3, "both": 2, "gaps_closed": 1, "gaps_kept": 0, "text_differs": 0, "previous_day": 0, "median_interval_ms": 16777.215, "suspected_gaps": [], "seq_gaps_a": 0, "seq_gaps_b": 0, "seq_gaps": []}
      ]
    }
    |}];
  let%bind again = Raw_merge.run ~a_dir ~b_dir ~out_dir date in
  print_s [%sexp (Result.is_error again : bool)];
  [%expect {| true |}];
  return ()
;;

let agg a =
  sprintf
    {|{"stream":"btcusdt@aggTrade","data":{"e":"aggTrade","E":1,"a":%d,"s":"BTCUSDT","p":"1","q":"1","f":1,"l":1,"T":1,"m":false}}|}
    a
;;

let%expect_test "sequence gaps: filled from the peer, or listed when both miss them" =
  let dir = Helpers.temp_dir () in
  let a_dir = dir ^/ "a"
  and b_dir = dir ^/ "b" in
  let trades ~data_dir ids =
    write_minute
      ~data_dir
      ~venue:"binance"
      ~stream:"trades"
      ~symbol:"BTCUSDT"
      ~name:"13-35"
      (List.map ids ~f:(fun id -> at "35" (sprintf "%02d.000000" id) (agg id)))
  in
  (* A misses 3 and 4, B misses 6; nobody has 8 *)
  let%bind () = trades ~data_dir:a_dir [ 1; 2; 5; 6; 7; 9 ] in
  let%bind () = trades ~data_dir:b_dir [ 1; 2; 3; 4; 5; 7; 9 ] in
  let%bind report =
    Raw_merge.run ~a_dir ~b_dir ~out_dir:(dir ^/ "out") (Date.of_string "2026-10-12")
  in
  let report = Or_error.ok_exn report in
  print_s [%sexp (report.findings : (Raw_merge.Series.t * Raw_merge.Findings.t) list)];
  [%expect
    {|
    ((((venue Binance) (stream Trades) (symbol_dir BTCUSDT))
      ((seq
        (((gaps
           (((first_missing 8) (last_missing 8) (at "2026-10-12 13:35:09Z"))))
          (gaps_a 2) (gaps_b 2))))
       (median_interval (1.048575s)) (suspected ()))))
    |}];
  let%bind json = Reader.file_contents (dir ^/ "out/_merge/2026-10-12.json") in
  String.split_lines json
  |> List.filter ~f:(String.is_substring ~substring:"seq_gaps")
  |> List.iter ~f:print_endline;
  [%expect
    {| {"venue": "binance", "stream": "trades", "symbol": "BTCUSDT", "minutes": 1, "only_a": 1, "only_b": 2, "both": 5, "gaps_closed": 0, "gaps_kept": 0, "text_differs": 0, "previous_day": 0, "median_interval_ms": 1048.575, "suspected_gaps": [], "seq_gaps_a": 2, "seq_gaps_b": 2, "seq_gaps": [{"first_missing": 8, "last_missing": 8, "at": "2026-10-12T13:35:09.000000Z"}]} |}];
  return ()
;;

let%expect_test "suspected gaps: a ticking stream silent in both copies" =
  let dir = Helpers.temp_dir () in
  let a_dir = dir ^/ "a"
  and b_dir = dir ^/ "b" in
  let bbo ~data_dir secs =
    write_minute
      ~data_dir
      ~venue:"hyperliquid"
      ~stream:"bbo"
      ~symbol:"BTC"
      ~name:"13-35"
      (List.map secs ~f:(fun ms ->
         at "35" (sprintf "%02d.%06d" (ms / 1000) (ms % 1000 * 1000)) (sprintf "q%d" ms)))
  in
  (* a quote every 100 ms; A is silent from 10 s to 30 s, B from 20 s to 40 s *)
  let every_100ms ~from ~until =
    List.init ((until - from) / 100) ~f:(fun i -> from + (i * 100))
  in
  let%bind () =
    bbo
      ~data_dir:a_dir
      (every_100ms ~from:0 ~until:10_000 @ every_100ms ~from:30_000 ~until:60_000)
  in
  let%bind () =
    bbo
      ~data_dir:b_dir
      (every_100ms ~from:0 ~until:20_000 @ every_100ms ~from:40_000 ~until:60_000)
  in
  let%bind report =
    Raw_merge.run
      ~silence:(Time_ns.Span.of_sec 5.)
      ~a_dir
      ~b_dir
      ~out_dir:(dir ^/ "out")
      (Date.of_string "2026-10-12")
  in
  let report = Or_error.ok_exn report in
  print_s [%sexp (report.findings : (Raw_merge.Series.t * Raw_merge.Findings.t) list)];
  [%expect
    {|
    ((((venue Hyperliquid) (stream Bbo) (symbol_dir BTC))
      ((seq ()) (median_interval (131.071ms))
       (suspected
        (((from "2026-10-12 00:00:00Z") (until "2026-10-12 13:35:00Z"))
         ((from "2026-10-12 13:35:19.9Z") (until "2026-10-12 13:35:30Z"))
         ((from "2026-10-12 13:35:59.9Z") (until "2026-10-13 00:00:00Z")))))))
    |}];
  return ()
;;

let%expect_test "frames stamped across midnight are matched with the previous day" =
  let dir = Helpers.temp_dir () in
  let a_dir = dir ^/ "a"
  and b_dir = dir ^/ "b" in
  let minute ~data_dir ~day ~name lines =
    let d = data_dir ^/ "raw/binance/l2/BTCUSDT/2026/10" ^/ day in
    let%bind () = Unix.mkdir ~p:() d in
    Writer.save
      (d ^/ name ^ ".ndjson")
      ~contents:(String.concat (List.map lines ~f:(fun l -> l ^ "\n")))
  in
  let depth u =
    sprintf
      {|{"stream":"btcusdt@depth@100ms","data":{"e":"depthUpdate","E":1,"T":1,"s":"BTCUSDT","U":%d,"u":%d,"pu":%d,"b":[],"a":[]}}|}
      u
      u
      (u - 1)
  in
  (* A stamps update 2 just before midnight, B just after; B misses update 3 *)
  let%bind () =
    minute
      ~data_dir:a_dir
      ~day:"11"
      ~name:"23-59"
      [ "2026-10-11T23:59:59.000000Z " ^ depth 1
      ; "2026-10-11T23:59:59.999000Z " ^ depth 2
      ]
  in
  let%bind () =
    minute
      ~data_dir:b_dir
      ~day:"11"
      ~name:"23-59"
      [ "2026-10-11T23:59:59.000100Z " ^ depth 1 ]
  in
  let%bind () =
    minute
      ~data_dir:a_dir
      ~day:"12"
      ~name:"00-00"
      [ "2026-10-12T00:00:00.100000Z " ^ depth 3
      ; "2026-10-12T00:00:00.200000Z " ^ depth 4
      ]
  in
  let%bind () =
    minute
      ~data_dir:b_dir
      ~day:"12"
      ~name:"00-00"
      [ "2026-10-12T00:00:00.000500Z " ^ depth 2
      ; "2026-10-12T00:00:00.200100Z " ^ depth 4
      ]
  in
  let out_dir = dir ^/ "out" in
  let%bind report = Raw_merge.run ~a_dir ~b_dir ~out_dir (Date.of_string "2026-10-12") in
  let report = Or_error.ok_exn report in
  print_s [%sexp (report.total : Raw_merge.Counts.t)];
  print_s [%sexp (report.findings : (Raw_merge.Series.t * Raw_merge.Findings.t) list)];
  let%bind merged =
    Helpers.unzstd (out_dir ^/ "raw/binance/l2/BTCUSDT/2026/10/12/00-00.ndjson.zst")
  in
  String.split_lines merged |> List.iter ~f:(fun l -> print_endline (String.prefix l 27));
  [%expect
    {|
    ((minutes 1) (only_a 1) (only_b 0) (both 1) (gaps_closed 0) (gaps_kept 0)
     (text_differs 0) (previous_day 1))
    ((((venue Binance) (stream L2) (symbol_dir BTCUSDT))
      ((seq (((gaps ()) (gaps_a 0) (gaps_b 1)))) (median_interval (131.071ms))
       (suspected
        (((from "2026-10-12 00:00:00.2Z") (until "2026-10-13 00:00:00Z")))))))
    2026-10-12T00:00:00.100000Z
    2026-10-12T00:00:00.200000Z
    |}];
  return ()
;;
