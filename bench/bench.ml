(* One synthetic busy minute of Binance BTCUSDT frames (aggTrade, bookTicker, markPrice)
   through the venue normalizer, the raw minute writer (including the zstd roll) and the
   event log writer. Prints frames/s and bytes/s per stage. *)

open! Core
open! Async
open Market_recorder

let minute = Time_ns.of_string_with_utc_offset "2026-10-12T09:15:00Z"

let frames ~per_second =
  let n = 60 * per_second in
  List.init n ~f:(fun i ->
    let recv_ts =
      Time_ns.add minute (Time_ns.Span.of_int_ns (i * (60_000_000_000 / n)))
    in
    let ms = Int63.to_int_exn (Time_ns.to_int63_ns_since_epoch recv_ts) / 1_000_000 in
    let px = 100_000. +. (Float.of_int (i % 997) *. 0.1) in
    let frame =
      match i % 10 with
      | 0 | 1 | 2 ->
        sprintf
          {|{"stream":"btcusdt@aggTrade","data":{"e":"aggTrade","E":%d,"a":%d,"s":"BTCUSDT","p":"%.2f","q":"0.005","f":%d,"l":%d,"T":%d,"m":%b}}|}
          ms
          i
          px
          (2 * i)
          ((2 * i) + 1)
          ms
          (i % 2 = 0)
      | 9 when i % 1000 = 9 ->
        sprintf
          {|{"stream":"btcusdt@markPrice@1s","data":{"e":"markPriceUpdate","E":%d,"s":"BTCUSDT","p":"%.2f","i":"%.2f","P":"%.2f","r":"0.0001","T":1791820800000}}|}
          ms
          px
          px
          px
      | _ ->
        sprintf
          {|{"stream":"btcusdt@bookTicker","data":{"e":"bookTicker","u":%d,"E":%d,"T":%d,"s":"BTCUSDT","b":"%.2f","B":"0.008","a":"%.2f","A":"0.001"}}|}
          i
          ms
          ms
          px
          (px +. 0.1)
    in
    recv_ts, frame)
;;

let rate ~count ~bytes span =
  let s = Time_ns.Span.to_sec span in
  sprintf
    "%8.0f frames/s  %7.1f MB/s  (%s)"
    (Float.of_int count /. s)
    (Float.of_int bytes /. s /. 1e6)
    (Time_ns.Span.to_string_hum ~decimals:1 span)
;;

let timed f =
  let start = Time_ns.now () in
  let%map x = f () in
  x, Time_ns.diff (Time_ns.now ()) start
;;

(* Two collectors' copies of the minute: B 300 us later, each missing a different 1%. *)
let merge ~frames ~bytes =
  let copy ~drop ~shift =
    List.filter_mapi frames ~f:(fun i (recv_ts, frame) ->
      Option.some_if
        (i % 100 <> drop)
        (Market_data.Raw_minute.Line.Frame
           { recv_ts = Time_ns.add recv_ts (Time_ns.Span.of_int_us shift)
           ; payload = frame
           }))
  in
  let a = copy ~drop:0 ~shift:0
  and b = copy ~drop:50 ~shift:300 in
  let count = List.length a + List.length b in
  let bytes = 2 * bytes in
  let (_ : _ list), counts, (_ : Raw_merge.Carry.t) =
    Raw_merge.merge_minute
      ~window:Raw_merge.default_window
      ~minute
      Raw_merge.Carry.empty
      ~a:(Some a)
      ~b:(Some b)
  in
  let start = Time_ns.now () in
  let (_ : _ list), (_ : Raw_merge.Counts.t), (_ : Raw_merge.Carry.t) =
    Raw_merge.merge_minute
      ~window:Raw_merge.default_window
      ~minute
      Raw_merge.Carry.empty
      ~a:(Some a)
      ~b:(Some b)
  in
  let in_memory = Time_ns.diff (Time_ns.now ()) start in
  let write_copy lines =
    let dir = Core_unix.mkdtemp (Filename.temp_dir_name ^/ "market-recorder-bench") in
    let raw = Raw_writer.create ~data_dir:dir ~on_closed:ignore () in
    List.iter lines ~f:(function
      | Market_data.Raw_minute.Line.Frame { recv_ts; payload } ->
        Raw_writer.write raw ~venue:Binance ~stream:Bbo ~symbol:"BTCUSDT" ~recv_ts payload
      | Disconnect -> ());
    let%map () = Raw_writer.close raw in
    dir
  in
  let%bind a_dir = write_copy a in
  let%bind b_dir = write_copy b in
  let out_dir = Core_unix.mkdtemp (Filename.temp_dir_name ^/ "market-recorder-bench") in
  let%map report, files =
    timed (fun () -> Raw_merge.run ~a_dir ~b_dir ~out_dir (Date.of_string "2026-10-12"))
  in
  let report = Or_error.ok_exn report in
  printf
    "merge of two copies: %d lines in, %d only_a, %d only_b, %d both\n"
    count
    counts.only_a
    counts.only_b
    counts.both;
  assert (Raw_merge.Counts.equal report.total { counts with minutes = 1 });
  printf "  merge in memory  %s\n" (rate ~count ~bytes in_memory);
  printf "  merge files      %s\n" (rate ~count ~bytes files)
;;

let run ~per_second =
  let frames = frames ~per_second in
  let count = List.length frames in
  let bytes = List.sum (module Int) frames ~f:(fun (_, f) -> String.length f) in
  let normalizer = Binance_client.Feed_normalizer.create ~l2_symbols:[] in
  let events, normalize =
    let start = Time_ns.now () in
    let events =
      List.concat_map frames ~f:(fun (recv_ts, frame) ->
        Binance_client.Feed_normalizer.frame normalizer ~recv_ts frame
        |> Or_error.ok_exn
        |> List.filter_map ~f:(function
          | Event e -> Some e
          | Need_snapshot _ -> None))
    in
    events, Time_ns.diff (Time_ns.now ()) start
  in
  let dir = Core_unix.mkdtemp (Filename.temp_dir_name ^/ "market-recorder-bench") in
  let%bind (), raw =
    timed (fun () ->
      let raw = Raw_writer.create ~data_dir:dir ~on_closed:ignore () in
      List.iter frames ~f:(fun (recv_ts, frame) ->
        Raw_writer.write raw ~venue:Binance ~stream:Bbo ~symbol:"BTCUSDT" ~recv_ts frame);
      Raw_writer.close raw)
  in
  let%bind (), norm =
    timed (fun () ->
      let norm = Norm_writer.create ~data_dir:dir () in
      List.iter events ~f:(Norm_writer.append norm);
      Norm_writer.close norm)
  in
  let%bind zst =
    Sys.ls_dir (dir ^/ "raw/binance/bbo/BTCUSDT/2026/10/12")
    >>= Deferred.List.map ~how:`Sequential ~f:(fun f ->
      Unix.stat (dir ^/ "raw/binance/bbo/BTCUSDT/2026/10/12" ^/ f) >>| Unix.Stats.size)
  in
  let total = Time_ns.Span.(normalize + raw + norm) in
  printf
    "one minute at %d frames/s: %d frames, %.1f MB raw, %d events, %.1f MB compressed\n"
    per_second
    count
    (Float.of_int bytes /. 1e6)
    (List.length events)
    (Float.of_int (List.sum (module Int) zst ~f:Int64.to_int_exn) /. 1e6);
  printf "  normalize        %s\n" (rate ~count ~bytes normalize);
  printf "  raw write + zstd %s\n" (rate ~count ~bytes raw);
  printf "  event log write  %s\n" (rate ~count ~bytes norm);
  printf "  all three        %s\n" (rate ~count ~bytes total);
  merge ~frames ~bytes
;;

let () =
  Command.async
    ~summary:"Bench one raw minute through the normalizer and both writers"
    (let%map_open.Command per_second =
       flag
         "-per-second"
         (optional_with_default 2000 int)
         ~doc:"N frames per second in the synthetic minute (default 2000)"
     in
     fun () -> run ~per_second)
  |> Command_unix.run
;;
