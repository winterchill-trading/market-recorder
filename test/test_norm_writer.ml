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

let l2 ~ts:s ?(kind = L2_update.Kind.Delta) ~bid ~ask () : Event.t =
  let level p : L2_update.Level.t = { price = Price.of_string p; size = Size.one } in
  L2
    { instrument = btc
    ; exch_ts = time s
    ; recv_ts = time s
    ; kind
    ; bids = [ level bid ]
    ; asks = [ level ask ]
    }
;;

(* a snapshot, then a delta every 20s over three minutes *)
let l2_events =
  l2 ~ts:"2026-10-12T09:00:00.1Z" ~kind:Snapshot ~bid:"99" ~ask:"101" ()
  :: List.init 9 ~f:(fun i ->
    let ts =
      Time_ns.add (time "2026-10-12T09:00:20Z") (Time_ns.Span.of_int_sec (20 * i))
      |> Time_ns.to_string_utc
    in
    l2 ~ts ~bid:(Int.to_string (98 - i)) ~ask:(Int.to_string (102 + i)) ())
;;

let record ?snapshot_interval () =
  let dir = temp_dir () in
  let t = Market_recorder.Norm_writer.create ?snapshot_interval ~data_dir:dir () in
  let feed = Replay_feed.of_events ~speed:0. (Pipe.of_list l2_events) in
  let%bind () = Market_recorder.Norm_writer.consume t feed ~on_event:ignore in
  let%bind () = Market_recorder.Norm_writer.close t in
  print_s
    [%sexp
      (List.map (Market_recorder.Norm_writer.snapshot_files t) ~f:(fun f ->
         String.chop_prefix_exn f ~prefix:(dir ^ "/"))
       : string list)];
  return dir
;;

let%expect_test "per-minute L2 snapshots by default" =
  let%bind dir = record () in
  [%expect {| (binance/BTCUSDT/norm/l2/_snapshots/2026-10-12.bin) |}];
  let%bind entries = Snapshot_index.load ~dir btc (Date.of_string "2026-10-12") in
  print_s [%sexp (List.length entries : int)];
  [%expect {| 3 |}];
  let%bind (_ : string) = record ~snapshot_interval:Time_ns.Span.zero () in
  [%expect {| () |}];
  return ()
;;

(* A stalled disk, made here with a FIFO nobody reads in place of the day's event log:
   opening it never returns, so nothing reaches the file. The writer still drains the feed
   without pushback, so the events wait in the writer's memory, not in the feed's pipes
   (which [norm_pipe_length] would show). *)
let%expect_test "a stalled event log buffers events in memory, not in the feed" =
  let dir = temp_dir () in
  let path = Event_log.path ~dir btc Trades (Date.of_string "2026-10-12") in
  let%bind () = Unix.mkdir ~p:() (Filename.dirname path) in
  let%bind () = Unix.mkfifo path in
  let t = Market_recorder.Norm_writer.create ~data_dir:dir () in
  let reader, writer = Pipe.create () in
  let feed = Replay_feed.of_events ~speed:0. reader in
  let seen = ref 0 in
  let consumed =
    Market_recorder.Norm_writer.consume t feed ~on_event:(fun _ -> incr seen)
  in
  let n = 10_000 in
  for i = 1 to n do
    Pipe.write_without_pushback
      writer
      (trade
         ~ts:(sprintf "2026-10-12T10:00:%02d.%06dZ" (i / 1000) (i % 1000))
         ~id:(Int.to_string i))
  done;
  Pipe.close writer;
  let%bind () = consumed in
  let flushed = Market_recorder.Norm_writer.flush t in
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 300) in
  print_s
    [%message
      "stalled"
        ~appended:(!seen : int)
        ~feed_pipe_length:(Pipe.length reader : int)
        ~flushed:(Deferred.is_determined flushed : bool)
        ~files:(Market_recorder.Norm_writer.files t : string list)];
  [%expect
    {| (stalled (appended 10000) (feed_pipe_length 0) (flushed false) (files ())) |}];
  return ()
;;
