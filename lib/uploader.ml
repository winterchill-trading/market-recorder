open! Core
open! Async

let pending_file ~data_dir = data_dir ^/ "upload-pending.sexp"

let relative ~data_dir file =
  match String.chop_prefix file ~prefix:(data_dir ^ "/") with
  | Some rel -> rel
  | None -> Filename.basename file
;;

let command_for ~command ~file ~rel =
  List.map command ~f:(fun arg ->
    String.substr_replace_all arg ~pattern:"{file}" ~with_:file
    |> String.substr_replace_all ~pattern:"{rel}" ~with_:rel)
;;

type t =
  { data_dir : string
  ; config : Config.Upload.t
  ; initial_backoff : Time_ns.Span.t
  ; max_backoff : Time_ns.Span.t
  ; throttle : unit Throttle.t
  ; save_sequencer : unit Throttle.Sequencer.t
  ; pending : String.Hash_set.t
  ; mutable uploaded : int
  ; mutable failures : int
  ; mutable idle : unit Ivar.t
  ; mutable closed : bool
  }

let pending t = Hash_set.to_list t.pending |> List.sort ~compare:String.compare
let uploaded t = t.uploaded
let failures t = t.failures

let save t =
  let files = pending t in
  Throttle.enqueue t.save_sequencer (fun () ->
    Writer.save_sexp (pending_file ~data_dir:t.data_dir) [%sexp (files : string list)])
;;

let update_idle t =
  if Hash_set.is_empty t.pending
  then Ivar.fill_if_empty t.idle ()
  else if Ivar.is_full t.idle
  then t.idle <- Ivar.create ()
;;

let idle t = if t.closed then return () else Ivar.read t.idle

let run_once t file =
  match
    command_for ~command:t.config.command ~file ~rel:(relative ~data_dir:t.data_dir file)
  with
  | [] -> return (Or_error.error_string "empty upload command")
  | prog :: args ->
    let%bind result = Process.run ~prog ~args () in
    (match result with
     | Ok _ when t.config.delete_after_upload ->
       Monitor.try_with_or_error (fun () -> Unix.unlink file)
     | Ok _ -> return (Ok ())
     | Error _ as e -> return e)
;;

let rec schedule t file ~backoff =
  if not t.closed
  then
    don't_wait_for
      (Throttle.enqueue t.throttle (fun () ->
         if t.closed
         then return ()
         else (
           match%map run_once t file with
           | Ok () ->
             t.uploaded <- t.uploaded + 1;
             Hash_set.remove t.pending file;
             update_idle t;
             don't_wait_for (save t)
           | Error e ->
             t.failures <- t.failures + 1;
             Log.Global.error_s
               [%message
                 "upload failed" (file : string) (backoff : Time_ns.Span.t) (e : Error.t)];
             let next = Time_ns.Span.min t.max_backoff (Time_ns.Span.scale backoff 2.) in
             upon (Clock_ns.after backoff) (fun () -> schedule t file ~backoff:next))))
;;

let enqueue t file =
  if (not t.closed) && not (Hash_set.mem t.pending file)
  then (
    Hash_set.add t.pending file;
    update_idle t;
    don't_wait_for (save t);
    schedule t file ~backoff:t.initial_backoff)
;;

let load ~data_dir =
  let path = pending_file ~data_dir in
  match%bind Sys.file_exists path with
  | `No | `Unknown -> return []
  | `Yes ->
    let%bind files =
      Reader.load_sexp path [%of_sexp: string list]
      >>| Or_error.tag ~tag:path
      >>| function
      | Ok files -> files
      | Error e ->
        Log.Global.error_s [%message "ignoring unreadable pending list" (e : Error.t)];
        []
    in
    Deferred.List.filter files ~how:`Sequential ~f:(fun file ->
      Sys.file_exists file
      >>| function
      | `Yes -> true
      | `No | `Unknown -> false)
;;

let create
  ?(max_concurrent = 4)
  ?(initial_backoff = Time_ns.Span.of_sec 1.)
  ?(max_backoff = Time_ns.Span.of_min 5.)
  ~data_dir
  config
  =
  let%bind () = Unix.mkdir ~p:() data_dir in
  let%bind previous = load ~data_dir in
  let t =
    { data_dir
    ; config
    ; initial_backoff
    ; max_backoff
    ; throttle =
        Throttle.create ~continue_on_error:true ~max_concurrent_jobs:max_concurrent
    ; save_sequencer = Throttle.Sequencer.create ~continue_on_error:true ()
    ; pending = String.Hash_set.create ()
    ; uploaded = 0
    ; failures = 0
    ; idle = Ivar.create ()
    ; closed = false
    }
  in
  update_idle t;
  List.iter previous ~f:(enqueue t);
  let%map () = save t in
  t
;;

let close ?(timeout = Time_ns.Span.of_sec 10.) t =
  if t.closed
  then return ()
  else (
    t.closed <- true;
    let running =
      Deferred.ignore_m
        (Clock_ns.with_timeout timeout (Throttle.prior_jobs_done t.throttle))
    in
    let%bind () = running in
    save t)
;;
