open! Core
open! Async

let utc = Time_float.Zone.utc

let parts time =
  let date, ofday = Time_ns.to_date_ofday time ~zone:utc in
  date, Time_ns.Span.to_parts (Time_ns.Ofday.to_span_since_start_of_day ofday)
;;

let format_ts time =
  let date, (p : Time_ns.Span.Parts.t) = parts time in
  sprintf "%sT%02d:%02d:%02d.%03d%03dZ" (Date.to_string date) p.hr p.min p.sec p.ms p.us
;;

let minute_ns = Int63.of_int64_exn 60_000_000_000L
let minute_of time = Int63.( / ) (Time_ns.to_int63_ns_since_epoch time) minute_ns

let safe_symbol symbol =
  String.map symbol ~f:(function
    | '/' | '\\' | ' ' -> '_'
    | c -> c)
;;

let path ~data_dir ~venue ~stream ~symbol time =
  let date, (p : Time_ns.Span.Parts.t) = parts time in
  String.concat
    ~sep:"/"
    [ data_dir
    ; "raw"
    ; Market_data.Venue.to_string venue
    ; Market_data.Stream.to_string stream
    ; safe_symbol symbol
    ; sprintf "%04d" (Date.year date)
    ; sprintf "%02d" (Month.to_int (Date.month date))
    ; sprintf "%02d" (Date.day date)
    ; sprintf "%02d-%02d.ndjson" p.hr p.min
    ]
;;

let compress_file path =
  let%bind contents = Reader.file_contents path in
  let%bind compressed = In_thread.run (fun () -> Zstd.compress ~level:3 contents) in
  let target = path ^ ".zst" in
  let%bind () =
    Writer.with_file ~append:true target ~f:(fun w ->
      Writer.write w compressed;
      return ())
  in
  let%map () = Unix.unlink path in
  target
;;

module Key = struct
  type t =
    { venue : Market_data.Venue.t
    ; stream : Market_data.Stream.t
    ; symbol : string
    }
  [@@deriving sexp_of, compare, hash]
end

module File = struct
  type t =
    { key : Key.t
    ; path : string
    ; minute : Int63.t
    ; writer : Writer.t option Deferred.t (** [None] if the file could not be opened *)
    ; buffer : Buffer.t
    }
end

let flush_bytes = 1 lsl 20
let close_timeout = Time_ns.Span.of_sec 5.

type t =
  { data_dir : string
  ; now : unit -> Time_ns.t
  ; on_closed : string -> unit
  ; on_error :
      venue:Market_data.Venue.t
      -> stream:Market_data.Stream.t
      -> symbol:string
      -> Error.t
      -> unit
  ; mutable last_error : (Error.t * Time_ns.t) option
  ; mutable error_count : int
  ; files : File.t Hashtbl.M(Key).t
  ; stop : unit Ivar.t
  ; mutable closing : unit Deferred.t list
  ; mutable closed : bool
  }

let open_files t =
  Hashtbl.data t.files
  |> List.map ~f:(fun (f : File.t) -> f.path)
  |> List.sort ~compare:String.compare
;;

(* Lines stay in [file.buffer] until the file is open. Writing through [upon file.writer]
   instead raced with [finish]: handlers of one ivar run in no fixed order, so
   [Writer.close] could start before a pending [Writer.write], which then hit the closed
   descriptor ([EBADF] from [fcntl]). *)
let last_error t = t.last_error
let error_count t = t.error_count

let record_error t ({ venue; stream; symbol } : Key.t) error =
  t.error_count <- t.error_count + 1;
  t.last_error <- Some (error, t.now ());
  t.on_error ~venue ~stream ~symbol error
;;

let write_out (file : File.t) =
  match Deferred.peek file.writer with
  | None -> ()
  | Some None -> Buffer.clear file.buffer
  | Some (Some w) ->
    if Buffer.length file.buffer > 0
    then (
      Writer.write w (Buffer.contents file.buffer);
      Buffer.clear file.buffer)
;;

(* Writes the rest of the buffer, closes the file and compresses it. Tracked in
   [t.closing] so that [close] can wait for every compression. *)
let finish t (file : File.t) =
  let d =
    match%bind file.writer with
    | None -> return ()
    | Some w ->
      write_out file;
      (match%map
         Monitor.try_with_or_error ~rest:`Log (fun () ->
           (* a writer that failed never reports flushed; do not wait forever *)
           let%bind () = Writer.close w ~force_close:(Clock_ns.after close_timeout) in
           compress_file file.path)
       with
       | Ok compressed -> t.on_closed compressed
       | Error e -> record_error t file.key e)
  in
  t.closing <- d :: t.closing;
  upon d (fun () ->
    t.closing <- List.filter t.closing ~f:(fun d' -> not (phys_equal d d')))
;;

let open_file t (key : Key.t) time =
  let path =
    path ~data_dir:t.data_dir ~venue:key.venue ~stream:key.stream ~symbol:key.symbol time
  in
  let writer =
    match%map
      Monitor.try_with_or_error ~rest:`Log (fun () ->
        let%bind () = Unix.mkdir ~p:() (Filename.dirname path) in
        Writer.open_file ~append:true path)
    with
    | Ok w ->
      Monitor.detach_and_iter_errors (Writer.monitor w) ~f:(fun exn ->
        record_error t key (Error.of_exn exn));
      Some w
    | Error e ->
      record_error t key e;
      None
  in
  { File.key; path; minute = minute_of time; writer; buffer = Buffer.create 4096 }
;;

let file_for t key time =
  let minute = minute_of time in
  match Hashtbl.find t.files key with
  | Some file when Int63.(file.File.minute >= minute) -> file
  | previous ->
    Option.iter previous ~f:(finish t);
    let file = open_file t key time in
    Hashtbl.set t.files ~key ~data:file;
    file
;;

let append t key ~recv_ts line =
  if t.closed then raise_s [%message "Raw_writer: write after close"];
  let file = file_for t key recv_ts in
  Buffer.add_string file.buffer line;
  if Buffer.length file.buffer >= flush_bytes then write_out file
;;

let one_line frame =
  if String.mem frame '\n' || String.mem frame '\r'
  then
    String.map frame ~f:(function
      | '\n' | '\r' -> ' '
      | c -> c)
  else frame
;;

let write t ~venue ~stream ~symbol ~recv_ts frame =
  append
    t
    { venue; stream; symbol }
    ~recv_ts
    (String.concat [ format_ts recv_ts; " "; one_line frame; "\n" ])
;;

let disconnect t ~venue ~stream ~symbol ~recv_ts =
  append t { venue; stream; symbol } ~recv_ts "\n"
;;

let flush t =
  Hashtbl.data t.files
  |> Deferred.List.iter ~how:`Parallel ~f:(fun (file : File.t) ->
    match%bind file.writer with
    | None -> return ()
    | Some w ->
      write_out file;
      Writer.flushed_or_failed_unit w)
;;

let wait_closing t = Deferred.all_unit t.closing

let roll t =
  let current = minute_of (t.now ()) in
  Hashtbl.filter_inplace t.files ~f:(fun file ->
    if Int63.(file.minute < current)
    then (
      finish t file;
      false)
    else true);
  wait_closing t
;;

let create
  ?(flush_interval = Time_ns.Span.of_int_ms 250)
  ?(now = Time_ns.now)
  ?(on_error = fun ~venue:_ ~stream:_ ~symbol:_ _ -> ())
  ~data_dir
  ~on_closed
  ()
  =
  let t =
    { data_dir
    ; now
    ; on_closed
    ; on_error
    ; last_error = None
    ; error_count = 0
    ; files = Hashtbl.create (module Key)
    ; stop = Ivar.create ()
    ; closing = []
    ; closed = false
    }
  in
  Clock_ns.every' ~stop:(Ivar.read t.stop) flush_interval (fun () ->
    let%bind () = flush t in
    roll t);
  t
;;

let close t =
  if t.closed
  then wait_closing t
  else (
    t.closed <- true;
    Ivar.fill_if_empty t.stop ();
    Hashtbl.iter t.files ~f:(finish t);
    Hashtbl.clear t.files;
    wait_closing t)
;;

let rec plain_files dir =
  match%bind Sys.is_directory dir with
  | `No | `Unknown -> return []
  | `Yes ->
    let%bind names = Sys.readdir dir in
    Array.to_list names
    |> Deferred.List.concat_map ~how:`Sequential ~f:(fun name ->
      let p = dir ^/ name in
      match%bind Sys.is_directory p with
      | `Yes -> plain_files p
      | `No | `Unknown ->
        return (if String.is_suffix name ~suffix:".ndjson" then [ p ] else []))
;;

let recover ~data_dir ~on_closed =
  let%bind files = plain_files (data_dir ^/ "raw") in
  Deferred.List.map
    ~how:`Sequential
    (List.sort files ~compare:String.compare)
    ~f:(fun path ->
      let%map compressed = compress_file path in
      on_closed compressed;
      compressed)
;;
