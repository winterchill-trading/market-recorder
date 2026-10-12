open! Core
open! Async
open Market_recorder
open Helpers

let%expect_test "timestamp format" =
  print_endline (Raw_writer.format_ts (time "2026-10-12T09:15:02.123456789Z"));
  print_endline (Raw_writer.format_ts (time "2026-01-02T00:00:00Z"));
  [%expect {|
    2026-10-12T09:15:02.123456Z
    2026-01-02T00:00:00.000000Z
    |}];
  return ()
;;

let%expect_test "path layout" =
  print_endline
    (Raw_writer.path
       ~data_dir:"/d"
       ~venue:Binance
       ~stream:L2
       ~symbol:"BTCUSDT"
       (time "2026-10-12T09:15:59.9Z"));
  [%expect {| /d/raw/binance/l2/BTCUSDT/2026/10/12/09-15.ndjson |}];
  return ()
;;

let%expect_test "minute roll compresses the previous file" =
  let dir = temp_dir () in
  let now = ref (time "2026-10-12T09:15:00Z") in
  let closed = Queue.create () in
  let t =
    Raw_writer.create
      ~flush_interval:(Time_ns.Span.of_int_ms 10)
      ~now:(fun () -> !now)
      ~data_dir:dir
      ~on_closed:(Queue.enqueue closed)
      ()
  in
  let write ts frame =
    Raw_writer.write
      t
      ~venue:Bybit
      ~stream:Trades
      ~symbol:"BTCUSDT"
      ~recv_ts:(time ts)
      frame
  in
  write "2026-10-12T09:15:01.5Z" {|{"topic":"publicTrade.BTCUSDT"}|};
  write "2026-10-12T09:15:02Z" "{\"a\":\n1}";
  Raw_writer.disconnect
    t
    ~venue:Bybit
    ~stream:Trades
    ~symbol:"BTCUSDT"
    ~recv_ts:(time "2026-10-12T09:15:03Z");
  let%bind () = Raw_writer.flush t in
  let%bind () = print_tree dir in
  [%expect {| raw/bybit/trades/BTCUSDT/2026/10/12/09-15.ndjson |}];
  write "2026-10-12T09:16:00.000001Z" "next";
  let%bind () = Raw_writer.roll t in
  let%bind () = print_tree dir in
  [%expect
    {|
    raw/bybit/trades/BTCUSDT/2026/10/12/09-15.ndjson.zst
    raw/bybit/trades/BTCUSDT/2026/10/12/09-16.ndjson
    |}];
  print_s [%sexp (Queue.length closed : int)];
  [%expect {| 1 |}];
  let%bind contents = unzstd (Queue.dequeue_exn closed) in
  print_string contents;
  [%expect
    {|
    2026-10-12T09:15:01.500000Z {"topic":"publicTrade.BTCUSDT"}
    2026-10-12T09:15:02.000000Z {"a": 1}

    |}];
  (* the wall clock moving on closes an idle file *)
  now := time "2026-10-12T09:17:00Z";
  let%bind () = Raw_writer.roll t in
  let%bind () = print_tree dir in
  [%expect
    {|
    raw/bybit/trades/BTCUSDT/2026/10/12/09-15.ndjson.zst
    raw/bybit/trades/BTCUSDT/2026/10/12/09-16.ndjson.zst
    |}];
  let%bind () = Raw_writer.close t in
  print_s [%sexp (Raw_writer.open_files t : string list)];
  [%expect {| () |}];
  return ()
;;

let%expect_test "close compresses open minutes, recover picks up leftovers" =
  let dir = temp_dir () in
  let t = Raw_writer.create ~data_dir:dir ~on_closed:ignore () in
  Raw_writer.write
    t
    ~venue:Hyperliquid
    ~stream:L2
    ~symbol:"BTC"
    ~recv_ts:(time "2026-10-12T23:59:59Z")
    "x";
  let%bind () = Raw_writer.close t in
  let%bind () = print_tree dir in
  [%expect {| raw/hyperliquid/l2/BTC/2026/10/12/23-59.ndjson.zst |}];
  let leftover = dir ^/ "raw/binance/bbo/ETHUSDT/2026/10/13/00-00.ndjson" in
  let%bind () = Unix.mkdir ~p:() (Filename.dirname leftover) in
  let%bind () = Writer.save leftover ~contents:"2026-10-13T00:00:00.000000Z {}\n" in
  let%bind recovered = Raw_writer.recover ~data_dir:dir ~on_closed:ignore in
  print_s
    [%sexp (List.map recovered ~f:(String.chop_prefix_exn ~prefix:dir) : string list)];
  [%expect {| (/raw/binance/bbo/ETHUSDT/2026/10/13/00-00.ndjson.zst) |}];
  let%bind () = print_tree dir in
  [%expect
    {|
    raw/binance/bbo/ETHUSDT/2026/10/13/00-00.ndjson.zst
    raw/hyperliquid/l2/BTC/2026/10/12/23-59.ndjson.zst
    |}];
  return ()
;;

let%expect_test "a second compression of the same minute appends a frame" =
  let dir = temp_dir () in
  let plain = dir ^/ "a.ndjson" in
  let%bind () = Writer.save plain ~contents:"one\n" in
  let%bind z = Raw_writer.compress_file plain in
  let%bind size1 = Unix.stat z >>| Unix.Stats.size in
  let%bind () = Writer.save plain ~contents:"two\n" in
  let%bind z' = Raw_writer.compress_file plain in
  let%bind size2 = Unix.stat z' >>| Unix.Stats.size in
  print_s [%sexp (String.equal z z' : bool), (Int64.(size2 = 2L * size1) : bool)];
  [%expect {| (true true) |}];
  return ()
;;

let%expect_test "close right after the first write keeps the line, 50 times" =
  let%bind results =
    Deferred.List.init ~how:`Sequential 50 ~f:(fun _ ->
      let dir = temp_dir () in
      let closed = Queue.create () in
      let t = Raw_writer.create ~data_dir:dir ~on_closed:(Queue.enqueue closed) () in
      Raw_writer.write
        t
        ~venue:Hyperliquid
        ~stream:L2
        ~symbol:"BTC"
        ~recv_ts:(time "2026-10-12T23:59:59Z")
        "x";
      let%bind () = Raw_writer.close t in
      unzstd (Queue.dequeue_exn closed))
  in
  print_s [%sexp (List.dedup_and_sort results ~compare:String.compare : string list)];
  [%expect {| ("2026-10-12T23:59:59.000000Z x\n") |}];
  return ()
;;

let%expect_test "a file that cannot be opened is reported, not raised" =
  let dir = temp_dir () in
  (* [raw] is a plain file, so no minute directory can be created under it *)
  let%bind () = Writer.save (dir ^/ "raw") ~contents:"" in
  let now = time "2026-10-12T09:15:30Z" in
  let t =
    Raw_writer.create
      ~now:(fun () -> now)
      ~on_error:(fun ~venue ~stream ~symbol _ ->
        print_s
          [%message
            "on_error"
              (venue : Market_data.Venue.t)
              (stream : Market_data.Stream.t)
              symbol])
      ~data_dir:dir
      ~on_closed:ignore
      ()
  in
  Raw_writer.write t ~venue:Okx ~stream:Bbo ~symbol:"BTC-USDT" ~recv_ts:now "x";
  let%bind () = Raw_writer.flush t in
  [%expect {| (on_error (venue Okx) (stream Bbo) BTC-USDT) |}];
  let%bind () = Raw_writer.close t in
  print_s
    [%sexp
      (Raw_writer.error_count t : int)
      , (Option.map (Raw_writer.last_error t) ~f:snd |> Option.map ~f:Raw_writer.format_ts
         : string option)];
  [%expect {| (1 (2026-10-12T09:15:30.000000Z)) |}];
  return ()
;;

let%expect_test "100 minute rolls keep the descriptor count flat" =
  let dir = temp_dir () in
  let now = ref (time "2026-10-12T09:00:30Z") in
  let closed = ref 0 in
  let t =
    Raw_writer.create
      ~flush_interval:(Time_ns.Span.of_day 1.)
      ~now:(fun () -> !now)
      ~data_dir:dir
      ~on_closed:(fun _ -> incr closed)
      ()
  in
  let minute i =
    now := Time_ns.add (time "2026-10-12T09:00:30Z") (Time_ns.Span.of_int_sec (60 * i));
    List.iter [ "BTCUSDT"; "ETHUSDT"; "SOLUSDT" ] ~f:(fun symbol ->
      Raw_writer.write t ~venue:Binance ~stream:Trades ~symbol ~recv_ts:!now "{}");
    let%bind () = Raw_writer.flush t in
    now := Time_ns.add !now (Time_ns.Span.of_int_sec 60);
    Raw_writer.roll t
  in
  (* warm up Async's thread pool and caches before counting *)
  let%bind () = Deferred.List.iter ~how:`Sequential (List.init 3 ~f:Fn.id) ~f:minute in
  let before = Process_metrics.open_fds () in
  let%bind () =
    Deferred.List.iter ~how:`Sequential (List.init 100 ~f:(fun i -> i + 3)) ~f:minute
  in
  let after = Process_metrics.open_fds () in
  let%bind () = Raw_writer.close t in
  print_s
    [%message
      ""
        ~closed:(!closed : int)
        ~open_files:(List.length (Raw_writer.open_files t) : int)
        ~fds_flat:([%equal: int option] before after : bool)];
  [%expect {| ((closed 309) (open_files 0) (fds_flat true)) |}];
  return ()
;;
