(* The raw line builder (reused timestamp buffer, frame copied straight into the file's
   buffer) against the [sprintf] and [String.concat] version it replaced. *)

open! Core
open! Async
open Market_recorder
open Helpers

module Reference = struct
  let format_ts time =
    let date, ofday = Time_ns.to_date_ofday time ~zone:Time_float.Zone.utc in
    let p = Time_ns.Span.to_parts (Time_ns.Ofday.to_span_since_start_of_day ofday) in
    sprintf "%sT%02d:%02d:%02d.%03d%03dZ" (Date.to_string date) p.hr p.min p.sec p.ms p.us
  ;;

  let one_line frame =
    String.map frame ~f:(function
      | '\n' | '\r' -> ' '
      | c -> c)
  ;;

  let line recv_ts frame = String.concat [ format_ts recv_ts; " "; one_line frame; "\n" ]
end

(* 1969-12-31T23:00Z to about 2100, so the pre-epoch fallback is exercised too *)
let time_gen =
  Quickcheck.Generator.map
    (Int.gen_incl (-3_600_000_000_000) 4_102_444_800_000_000_000)
    ~f:(fun ns -> Time_ns.of_int63_ns_since_epoch (Int63.of_int ns))
;;

let%expect_test "format_ts matches the sprintf version" =
  Quickcheck.test ~trials:100_000 time_gen ~sexp_of:Time_ns.sexp_of_t ~f:(fun t ->
    [%test_result: string] (Raw_writer.format_ts t) ~expect:(Reference.format_ts t));
  List.iter
    [ "1969-12-31T23:59:59.999999999Z"
    ; "1970-01-01T00:00:00Z"
    ; "2026-10-12T09:15:59.999999999Z"
    ; "2026-10-12T09:16:00.000000999Z"
    ]
    ~f:(fun s -> print_endline (Raw_writer.format_ts (time s)));
  [%expect
    {|
    1969-12-31T23:59:59.999999Z
    1970-01-01T00:00:00.000000Z
    2026-10-12T09:15:59.999999Z
    2026-10-12T09:16:00.000000Z
    |}];
  return ()
;;

(* Frames over a few minutes (so the cached minute prefix changes), some with newlines,
   written through one handle; the decompressed files, in path order, must equal the
   reference lines. *)
let case_gen =
  let open Quickcheck.Generator in
  let frame =
    String.gen_with_length
      40
      (Quickcheck.Generator.of_list [ 'a'; '{'; '"'; ':'; ' '; '\n'; '\r'; '9' ])
  in
  let step = Int.gen_incl 0 20_000_000_000 in
  tuple2 time_gen (list_with_length 200 (tuple2 step frame))
;;

let%expect_test "written files match the reference lines" =
  let cases =
    Quickcheck.random_sequence ~seed:(`Deterministic "raw-line") case_gen
    |> Fn.flip Sequence.take 20
    |> Sequence.to_list
  in
  let%map () =
    Deferred.List.iter ~how:`Sequential cases ~f:(fun (start, frames) ->
      let dir = temp_dir () in
      let closed = Queue.create () in
      let raw =
        Raw_writer.create
          ~now:(fun () -> Time_ns.epoch)
          ~data_dir:dir
          ~on_closed:(Queue.enqueue closed)
          ()
      in
      let h = Raw_writer.handle raw ~venue:Kraken ~stream:Trades ~symbol:"XBT/USD" in
      let expected = Buffer.create 4096 in
      let (_ : Time_ns.t) =
        List.fold frames ~init:start ~f:(fun recv_ts (step, frame) ->
          let recv_ts = Time_ns.add recv_ts (Time_ns.Span.of_int_ns step) in
          Raw_writer.write_handle raw h ~recv_ts frame;
          Buffer.add_string expected (Reference.line recv_ts frame);
          recv_ts)
      in
      let%bind () = Raw_writer.close raw in
      let%map contents =
        Queue.to_list closed
        |> List.sort ~compare:String.compare
        |> Deferred.List.map ~how:`Sequential ~f:unzstd
      in
      [%test_result: string] (String.concat contents) ~expect:(Buffer.contents expected))
  in
  [%expect {| |}]
;;

let%expect_test "words per line through an open handle" =
  let dir = temp_dir () in
  let raw = Raw_writer.create ~data_dir:dir ~on_closed:ignore () in
  let h = Raw_writer.handle raw ~venue:Binance ~stream:Bbo ~symbol:"BTCUSDT" in
  let start = time "2026-10-12T09:15:00Z" in
  let at i = Time_ns.add start (Time_ns.Span.of_int_us (i * 37)) in
  let frame = {|{"u":1,"b":"100000.10","a":"100000.20"}|} in
  let write i = Raw_writer.write_handle raw h ~recv_ts:(at i) frame in
  write 0;
  let%bind () = Raw_writer.flush raw in
  (* The first lines after the file opens allocate a few hundred words once (the buffer's
     growth past the minor heap limit wakes the major GC), and each doubling of the line
     buffer costs 3 words; 2000 lines of warm-up leave room for 1000 more. *)
  for i = 1 to 2000 do
    write i
  done;
  let before = Gc.minor_words () in
  for i = 2001 to 3000 do
    write i
  done;
  print_s [%message "" ~words:(Gc.minor_words () - before : int)];
  [%expect {| (words 0) |}];
  Raw_writer.close raw
;;
