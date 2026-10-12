open! Core
open! Async
open Market_recorder

(* values vary between machines and runs; print names and label keys *)
let shape text =
  String.split_lines text
  |> List.filter ~f:(fun l ->
    (not (String.is_prefix l ~prefix:"#"))
    (* only on Linux *)
    && not (String.is_prefix l ~prefix:"market_recorder_resident"))
  |> List.iter ~f:(fun l ->
    let name = String.take_while l ~f:(fun c -> Char.is_alphanum c || Char.equal c '_') in
    let labels =
      match String.lsplit2 l ~on:'{' with
      | None -> []
      | Some (_, rest) ->
        String.split (String.take_while rest ~f:(fun c -> not (Char.equal c '}'))) ~on:','
        |> List.map ~f:(fun kv ->
          String.take_while kv ~f:(fun c -> not (Char.equal c '=')))
    in
    print_s [%sexp (name : string), (labels : string list)])
;;

let%expect_test "process gauges" =
  shape (Process_metrics.render ());
  [%expect
    {|
    (market_recorder_build_info (version ocaml))
    (market_recorder_open_fds ())
    (market_recorder_max_fds ())
    (market_recorder_gc_minor_collections_total ())
    (market_recorder_gc_major_collections_total ())
    (market_recorder_gc_compactions_total ())
    (market_recorder_gc_heap_words ())
    (market_recorder_gc_top_heap_words ())
    |}];
  print_s [%sexp (String.is_empty (Process_metrics.version ()) : bool)];
  [%expect {| false |}];
  print_s
    [%sexp
      (Option.is_some (Process_metrics.rss_bytes ())
       |> Bool.equal
            (String.equal (Core_unix.Utsname.sysname (Core_unix.uname ())) "Linux")
       : bool)];
  [%expect {| true |}];
  return ()
;;

let%expect_test "the descriptor limit is known and at least the open count" =
  let soft, _ = Option.value_exn (Process_metrics.fd_limits ()) in
  let open_fds = Option.value_exn (Process_metrics.open_fds ()) in
  print_s
    [%sexp (Option.for_all soft ~f:(fun soft -> Int64.(soft >= of_int open_fds)) : bool)];
  [%expect {| true |}];
  return ()
;;
