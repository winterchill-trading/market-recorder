open! Core
open! Async

let utc = Time_float.Zone.utc

let parts time =
  let date, ofday = Time_ns.to_date_ofday time ~zone:utc in
  date, Time_ns.Span.to_parts (Time_ns.Ofday.to_span_since_start_of_day ofday)
;;

let format_ts_slow time =
  let date, (p : Time_ns.Span.Parts.t) = parts time in
  sprintf "%sT%02d:%02d:%02d.%03d%03dZ" (Date.to_string date) p.hr p.min p.sec p.ms p.us
;;

let minute_ns = Int63.of_int64_exn 60_000_000_000L
let minute_of time = Int63.( / ) (Time_ns.to_int63_ns_since_epoch time) minute_ns

(* The timestamp of the line being written, in a buffer reused for every line. The
   [YYYY-MM-DDTHH:MM:] prefix is cut from [format_ts_slow] once per minute, so the bytes
   match it by construction; only seconds and microseconds are written per line. Times
   before the epoch or past year 9999 take the slow path. *)
module Ts = struct
  let length = String.length "2026-10-12T09:15:02.123456Z"
  let prefix = String.length "2026-10-12T09:15:"
  let minute_ns = 60_000_000_000

  type t =
    { bytes : Bytes.t
    ; mutable minute : int (** of the prefix in [bytes]; -1 before the first line *)
    }

  let create () = { bytes = Bytes.make length 'Z'; minute = -1 }

  let digits bytes ~pos ~width n =
    let n = ref n in
    for i = pos + width - 1 downto pos do
      Bytes.unsafe_set bytes i (Char.unsafe_of_int (Char.to_int '0' + (!n mod 10)));
      n := !n / 10
    done
  ;;

  (* Fills [t.bytes] and returns [true], or returns [false] for a time to format with
     [format_ts_slow]. *)
  let fill t time =
    let ns = Int63.to_int_exn (Time_ns.to_int63_ns_since_epoch time) in
    if ns < 0
    then false
    else (
      let minute = ns / minute_ns in
      if minute <> t.minute
      then (
        let s = format_ts_slow time in
        if String.length s = length
        then (
          Bytes.From_string.blit ~src:s ~src_pos:0 ~dst:t.bytes ~dst_pos:0 ~len:length;
          t.minute <- minute)
        else t.minute <- -1);
      if t.minute < 0
      then false
      else (
        let in_minute = ns - (minute * minute_ns) in
        digits t.bytes ~pos:prefix ~width:2 (in_minute / 1_000_000_000);
        digits t.bytes ~pos:(prefix + 3) ~width:6 (in_minute mod 1_000_000_000 / 1_000);
        true))
  ;;
end

let format_ts time =
  let ts = Ts.create () in
  if Ts.fill ts time then Bytes.to_string ts.bytes else format_ts_slow time
;;

let safe_symbol symbol =
  String.map symbol ~f:(function
    | '/' | '\\' | ' ' -> '_'
    | c -> c)
;;

let path ?collector ~data_dir ~venue ~stream ~symbol time =
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
    ; sprintf
        "%02d-%02d%s.ndjson"
        p.hr
        p.min
        (Option.value_map collector ~default:"" ~f:(fun c -> "." ^ c))
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

(* A stream's current minute file, [Null] between minutes. Slots are never removed, so a
   caller can look one up once ({!handle}) and keep it. *)
module Handle = struct
  type t =
    { key : Key.t
    ; mutable file : File.t or_null
    }
end

let flush_bytes = 1 lsl 20
let close_timeout = Time_ns.Span.of_sec 5.

type t =
  { data_dir : string
  ; collector : string option
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
  ; slots : Handle.t Hashtbl.M(Key).t
  ; ts : Ts.t
  ; stop : unit Ivar.t
  ; mutable closing : unit Deferred.t list
  ; mutable closed : bool
  }

let files t =
  Hashtbl.fold t.slots ~init:[] ~f:(fun ~key:_ ~data:(slot : Handle.t) acc ->
    match slot.file with
    | This file -> file :: acc
    | Null -> acc)
;;

let open_files t =
  files t |> List.map ~f:(fun (f : File.t) -> f.path) |> List.sort ~compare:String.compare
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
    path
      ?collector:t.collector
      ~data_dir:t.data_dir
      ~venue:key.venue
      ~stream:key.stream
      ~symbol:key.symbol
      time
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

let handle t ~venue ~stream ~symbol =
  let key = { Key.venue; stream; symbol } in
  Hashtbl.find_or_add t.slots key ~default:(fun () -> { Handle.key; file = Null })
;;

let file_for t (slot : Handle.t) time =
  let minute = minute_of time in
  match slot.file with
  | This file when Int63.(file.minute >= minute) -> file
  | This previous ->
    finish t previous;
    let file = open_file t slot.key time in
    slot.file <- This file;
    file
  | Null ->
    let file = open_file t slot.key time in
    slot.file <- This file;
    file
;;

let check_open t = if t.closed then raise_s [%message "Raw_writer: write after close"]

let after_append (file : File.t) =
  if Buffer.length file.buffer >= flush_bytes then write_out file
;;

(* Newlines inside a frame become spaces so that a line is always one record. *)
let add_frame buffer frame =
  if String.mem frame '\n' || String.mem frame '\r'
  then
    String.iter frame ~f:(function
      | '\n' | '\r' -> Buffer.add_char buffer ' '
      | c -> Buffer.add_char buffer c)
  else Buffer.add_string buffer frame
;;

let write_handle t slot ~recv_ts frame =
  check_open t;
  let file = file_for t slot recv_ts in
  if Ts.fill t.ts recv_ts
  then Buffer.add_bytes file.buffer t.ts.bytes
  else Buffer.add_string file.buffer (format_ts_slow recv_ts);
  Buffer.add_char file.buffer ' ';
  add_frame file.buffer frame;
  Buffer.add_char file.buffer '\n';
  after_append file
;;

let write t ~venue ~stream ~symbol ~recv_ts frame =
  write_handle t (handle t ~venue ~stream ~symbol) ~recv_ts frame
;;

let disconnect_handle t slot ~recv_ts =
  check_open t;
  let file = file_for t slot recv_ts in
  Buffer.add_char file.buffer '\n';
  after_append file
;;

let disconnect t ~venue ~stream ~symbol ~recv_ts =
  disconnect_handle t (handle t ~venue ~stream ~symbol) ~recv_ts
;;

let flush t =
  files t
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
  Hashtbl.iter t.slots ~f:(fun (slot : Handle.t) ->
    match slot.file with
    | This file when Int63.(file.minute < current) ->
      finish t file;
      slot.file <- Null
    | This _ | Null -> ());
  wait_closing t
;;

let create
  ?(flush_interval = Time_ns.Span.of_int_ms 250)
  ?(now = Time_ns.now)
  ?(on_error = fun ~venue:_ ~stream:_ ~symbol:_ _ -> ())
  ?collector
  ~data_dir
  ~on_closed
  ()
  =
  let t =
    { data_dir
    ; collector
    ; now
    ; on_closed
    ; on_error
    ; last_error = None
    ; error_count = 0
    ; slots = Hashtbl.create (module Key)
    ; ts = Ts.create ()
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
    Hashtbl.iter t.slots ~f:(fun (slot : Handle.t) ->
      match slot.file with
      | This file ->
        finish t file;
        slot.file <- Null
      | Null -> ());
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
