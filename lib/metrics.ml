open! Core

module Key = struct
  type t =
    { venue : Market_data.Venue.t
    ; stream : Market_data.Stream.t
    ; symbol : string
    }
  [@@deriving sexp, compare, equal, hash]
end

module Counters = struct
  type t =
    { registered : Time_ns.t
    ; mutable frames : int
    ; mutable bytes : int
    ; mutable events : int
    ; mutable clamped : int
    ; mutable last_frame : Time_ns.t option
    }
end

type t =
  { now : unit -> Time_ns.t
  ; counters : Counters.t Hashtbl.M(Key).t
  ; mutable upload_source : (unit -> int * int * int) option
  }

let create ?(now = Time_ns.now) () =
  { now; counters = Hashtbl.create (module Key); upload_source = None }
;;

let get t key =
  Hashtbl.find_or_add t.counters key ~default:(fun () ->
    { Counters.registered = t.now ()
    ; frames = 0
    ; bytes = 0
    ; events = 0
    ; clamped = 0
    ; last_frame = None
    })
;;

let register t key = ignore (get t key : Counters.t)

let frame t key ~recv_ts ~bytes =
  let c = get t key in
  c.frames <- c.frames + 1;
  c.bytes <- c.bytes + bytes;
  c.last_frame <- Some recv_ts
;;

let clamp_recv_ts t key recv_ts =
  let c = get t key in
  match c.last_frame with
  | Some last when Time_ns.( < ) recv_ts last ->
    c.clamped <- c.clamped + 1;
    last
  | _ -> recv_ts
;;

let event t key =
  let c = get t key in
  c.events <- c.events + 1
;;

let set_upload_source t f = t.upload_source <- Some f

let age t (c : Counters.t) =
  Time_ns.diff (t.now ()) (Option.value c.last_frame ~default:c.registered)
;;

module Health = struct
  type stale =
    { key : Key.t
    ; last_frame_age : Time_ns.Span.t
    ; frames : int
    }
  [@@deriving sexp_of]

  type t =
    | Healthy
    | Stale of stale list
  [@@deriving sexp_of]
end

let sorted t =
  Hashtbl.to_alist t.counters |> List.sort ~compare:(fun (a, _) (b, _) -> Key.compare a b)
;;

let health ?(max_age = Time_ns.Span.of_sec 30.) t =
  let stale =
    List.filter_map (sorted t) ~f:(fun (key, c) ->
      let last_frame_age = age t c in
      if Time_ns.Span.( > ) last_frame_age max_age
      then Some { Health.key; last_frame_age; frames = c.frames }
      else None)
  in
  if List.is_empty stale then Health.Healthy else Stale stale
;;

let escape s =
  String.concat_map s ~f:(function
    | '\\' -> "\\\\"
    | '"' -> "\\\""
    | '\n' -> "\\n"
    | c -> String.of_char c)
;;

let labels (k : Key.t) =
  sprintf
    {|{venue="%s",stream="%s",symbol="%s"}|}
    (Market_data.Venue.to_string k.venue)
    (Market_data.Stream.to_string k.stream)
    (escape k.symbol)
;;

let render t =
  let buf = Buffer.create 1024 in
  let rows = sorted t in
  let family name ~type_ ~help value =
    bprintf buf "# HELP %s %s\n# TYPE %s %s\n" name help name type_;
    List.iter rows ~f:(fun (key, c) ->
      bprintf buf "%s%s %s\n" name (labels key) (value c))
  in
  family
    "market_recorder_frames_total"
    ~type_:"counter"
    ~help:"Raw frames received."
    (fun c -> Int.to_string c.frames);
  family
    "market_recorder_bytes_total"
    ~type_:"counter"
    ~help:"Bytes of raw frames received."
    (fun c -> Int.to_string c.bytes);
  family
    "market_recorder_events_total"
    ~type_:"counter"
    ~help:"Normalized events written."
    (fun c -> Int.to_string c.events);
  family
    "market_recorder_clamped_frames_total"
    ~type_:"counter"
    ~help:"Raw frames whose recv_ts went backwards and was raised to the previous one."
    (fun c -> Int.to_string c.clamped);
  family
    "market_recorder_last_frame_age_seconds"
    ~type_:"gauge"
    ~help:"Seconds since the last raw frame (since start if none yet)."
    (fun c -> sprintf "%.3f" (Time_ns.Span.to_sec (age t c)));
  Option.iter t.upload_source ~f:(fun f ->
    let uploaded, failures, pending = f () in
    let scalar name ~type_ ~help v =
      bprintf buf "# HELP %s %s\n# TYPE %s %s\n%s %d\n" name help name type_ name v
    in
    scalar
      "market_recorder_uploads_total"
      ~type_:"counter"
      ~help:"Files uploaded."
      uploaded;
    scalar
      "market_recorder_upload_failures_total"
      ~type_:"counter"
      ~help:"Failed upload command runs."
      failures;
    scalar
      "market_recorder_upload_pending"
      ~type_:"gauge"
      ~help:"Files waiting to be uploaded."
      pending);
  Buffer.contents buf
;;
