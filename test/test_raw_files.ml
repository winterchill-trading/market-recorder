(* Collector ids in raw minute file names. *)

open! Core
open! Async
open Market_recorder
open Helpers

let%expect_test "names with and without a collector id" =
  List.iter
    [ "13-35.ndjson"
    ; "13-35.ndjson.zst"
    ; "13-35.tokyo_1.ndjson.zst"
    ; "13-35.a.b.ndjson"
    ; "13-3x.ndjson"
    ; "upload-pending.sexp"
    ]
    ~f:(fun name ->
      print_s
        [%sexp
          (name : string), (Raw_files.parse_name name : (string option * string) option)]);
  [%expect
    {|
    (13-35.ndjson ((() 13-35.ndjson)))
    (13-35.ndjson.zst ((() 13-35.ndjson.zst)))
    (13-35.tokyo_1.ndjson.zst (((tokyo_1) 13-35.ndjson.zst)))
    (13-35.a.b.ndjson ())
    (13-3x.ndjson ())
    (upload-pending.sexp ())
    |}];
  print_s [%sexp (Raw_files.check_collector "a-b" : unit Or_error.t)];
  [%expect {| (Error ("collector id must be 1 to 32 of [A-Za-z0-9_]" a-b)) |}];
  return ()
;;

let%expect_test "a writer with a collector id, and listing one collector's files" =
  let dir = temp_dir () in
  let write ?collector () =
    let t = Raw_writer.create ?collector ~data_dir:dir ~on_closed:ignore () in
    Raw_writer.write
      t
      ~venue:Binance
      ~stream:Trades
      ~symbol:"BTCUSDT"
      ~recv_ts:(time "2026-10-12T13:35:01Z")
      (Option.value collector ~default:"none");
    Raw_writer.close t
  in
  let%bind () = write () in
  let%bind () = write ~collector:"a" () in
  let%bind () = write ~collector:"b" () in
  let%bind () = print_tree dir in
  [%expect
    {|
    raw/binance/trades/BTCUSDT/2026/10/12/13-35.a.ndjson.zst
    raw/binance/trades/BTCUSDT/2026/10/12/13-35.b.ndjson.zst
    raw/binance/trades/BTCUSDT/2026/10/12/13-35.ndjson.zst
    |}];
  let date = Date.of_string "2026-10-12" in
  let%bind () =
    Deferred.List.iter ~how:`Sequential [ None; Some "a"; Some "c" ] ~f:(fun collector ->
      let%map files = Raw_files.files ?collector ~data_dir:dir date in
      List.iter files ~f:(fun (f : Market_data.Raw_minute.File.t) ->
        printf
          "%s %s %s\n"
          (Option.value collector ~default:"-")
          (Raw_writer.format_ts f.minute)
          (String.chop_prefix_exn f.path ~prefix:dir)))
  in
  [%expect
    {|
    - 2026-10-12T13:35:00.000000Z /raw/binance/trades/BTCUSDT/2026/10/12/13-35.ndjson.zst
    a 2026-10-12T13:35:00.000000Z /raw/binance/trades/BTCUSDT/2026/10/12/13-35.a.ndjson.zst
    |}];
  return ()
;;
