open! Core
open! Async
open Market_recorder
open Helpers

let%expect_test "command substitution" =
  print_s
    [%sexp
      (Uploader.command_for
         ~command:[ "rclone"; "copyto"; "{file}"; "remote:bucket/{rel}" ]
         ~file:"/d/raw/a.zst"
         ~rel:(Uploader.relative ~data_dir:"/d" "/d/raw/a.zst")
       : string list)];
  [%expect {| (rclone copyto /d/raw/a.zst remote:bucket/raw/a.zst) |}];
  return ()
;;

(* copies [{file}] to [<remote>/{rel}], failing while [<gate>] is missing *)
let fake_copy ~remote ~gate : Config.Upload.t =
  { command =
      [ "sh"
      ; "-c"
      ; {|test -e "$1" && mkdir -p "$(dirname "$3")" && cp "$2" "$3"|}
      ; "sh"
      ; gate
      ; "{file}"
      ; remote ^/ "{rel}"
      ]
  ; delete_after_upload = true
  }
;;

let make_file dir rel =
  let path = dir ^/ rel in
  let%bind () = Unix.mkdir ~p:() (Filename.dirname path) in
  let%map () = Writer.save path ~contents:rel in
  path
;;

let%expect_test "uploads, retries, and survives a restart" =
  Log.Global.set_output [];
  let root = temp_dir () in
  let data_dir = root ^/ "data" in
  let remote = root ^/ "remote" in
  let gate = root ^/ "gate" in
  let config = fake_copy ~remote ~gate in
  let backoff = Time_ns.Span.of_int_ms 20 in
  let%bind t =
    Uploader.create ~initial_backoff:backoff ~max_backoff:backoff ~data_dir config
  in
  let%bind a = make_file data_dir "raw/x/a.ndjson.zst" in
  let%bind b = make_file data_dir "raw/x/b.ndjson.zst" in
  Uploader.enqueue t a;
  Uploader.enqueue t b;
  Uploader.enqueue t a;
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 100) in
  print_s
    [%sexp
      (List.length (Uploader.pending t) : int)
      , (Uploader.uploaded t : int)
      , (Uploader.failures t > 0 : bool)];
  [%expect {| (2 0 true) |}];
  let%bind () = Uploader.close t in
  let%bind saved =
    Reader.load_sexp_exn (Uploader.pending_file ~data_dir) [%of_sexp: string list]
  in
  print_s [%sexp (List.length saved : int)];
  [%expect {| 2 |}];
  (* a new run picks the pending files up; the remote now works *)
  let%bind () = Writer.save gate ~contents:"" in
  let%bind t = Uploader.create ~data_dir config in
  let%bind () = Uploader.idle t in
  print_s [%sexp (Uploader.pending t : string list), (Uploader.uploaded t : int)];
  [%expect {| (() 2) |}];
  let%bind () = Uploader.close t in
  let%bind () = print_tree root in
  [%expect
    {|
    data/upload-pending.sexp
    gate
    remote/raw/x/a.ndjson.zst
    remote/raw/x/b.ndjson.zst
    |}];
  let%bind saved =
    Reader.load_sexp_exn (Uploader.pending_file ~data_dir) [%of_sexp: string list]
  in
  print_s [%sexp (saved : string list)];
  [%expect {| () |}];
  return ()
;;
