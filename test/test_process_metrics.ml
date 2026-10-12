open! Core
open! Async
open Market_recorder

(* values vary between machines and runs; print names and label keys *)
let shape text =
  String.split_lines text
  |> List.filter ~f:(fun l -> not (String.is_prefix l ~prefix:"#"))
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
  [%expect {| (market_recorder_build_info (version ocaml)) |}];
  print_s [%sexp (String.is_empty (Process_metrics.version ()) : bool)];
  [%expect {| false |}];
  return ()
;;
