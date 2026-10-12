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
    ; mutable raw : bool
    ; mutable frames : int
    ; mutable bytes : int
    ; mutable events : int
    ; mutable clamped : int
    ; mutable pipe_length : unit -> int
    ; mutable stale : bool
    ; mutable flaps : int
    ; mutable last_frame : Time_ns.t option
    }
end

module Feed_stats = struct
  type t =
    { frames : int
    ; parse_errors : int
    ; reconnects : int
    }
  [@@deriving sexp_of, equal]

  let zero = { frames = 0; parse_errors = 0; reconnects = 0 }

  let ( + ) a b =
    { frames = a.frames + b.frames
    ; parse_errors = a.parse_errors + b.parse_errors
    ; reconnects = a.reconnects + b.reconnects
    }
  ;;
end

type t =
  { now : unit -> Time_ns.t
  ; counters : Counters.t Hashtbl.M(Key).t
  ; mutable upload_source : (unit -> int * int * int) option
  ; mutable feed_stats_sources : (Market_data.Venue.t * (unit -> Feed_stats.t)) list
  ; mutable flush_error_source : unit -> (Error.t * Time_ns.t) option
  ; mutable lags : (Market_data.Venue.t * Time_ns.Span.t) list (** sorted by venue *)
  ; mutable scalars : (string * string * string * (unit -> float option)) list
  (** name, type, help, value; in the order added *)
  }

let create ?(now = Time_ns.now) () =
  { now
  ; lags = []
  ; scalars = []
  ; counters = Hashtbl.create (module Key)
  ; upload_source = None
  ; feed_stats_sources = []
  ; flush_error_source = (fun () -> None)
  }
;;

let get t key =
  Hashtbl.find_or_add t.counters key ~default:(fun () ->
    { Counters.registered = t.now ()
    ; raw = true
    ; frames = 0
    ; bytes = 0
    ; events = 0
    ; clamped = 0
    ; pipe_length = (fun () -> 0)
    ; stale = false
    ; flaps = 0
    ; last_frame = None
    })
;;

let register ?(raw = true) t key = (get t key).raw <- raw

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

let set_pipe_length t key f = (get t key).pipe_length <- f
let set_upload_source t f = t.upload_source <- Some f

let exchange_lag t ~venue lag =
  t.lags
  <- List.Assoc.add t.lags venue lag ~equal:Market_data.Venue.equal
     |> List.sort ~compare:(fun (a, _) (b, _) -> Market_data.Venue.compare a b)
;;

let exchange_lags t = t.lags
let add_scalar t ~name ~type_ ~help f = t.scalars <- t.scalars @ [ name, type_, help, f ]
let set_flush_error_source t f = t.flush_error_source <- f

let add_feed_stats_source t ~venue f =
  t.feed_stats_sources <- (venue, f) :: t.feed_stats_sources
;;

let feed_stats t =
  let sums = Hashtbl.create (module Market_data.Venue) in
  List.iter t.feed_stats_sources ~f:(fun (venue, f) ->
    Hashtbl.update sums venue ~f:(fun sum ->
      Feed_stats.( + ) (Option.value sum ~default:Feed_stats.zero) (f ())));
  Hashtbl.to_alist sums
  |> List.sort ~compare:(fun (a, _) (b, _) -> Market_data.Venue.compare a b)
;;

module Flush_error = struct
  type t =
    { error : Error.t
    ; age : Time_ns.Span.t
    }
  [@@deriving sexp_of]
end

let flush_error t =
  Option.map (t.flush_error_source ()) ~f:(fun (error, at) ->
    { Flush_error.error; age = Time_ns.diff (t.now ()) at })
;;

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

let default_max_age = Time_ns.Span.of_sec 30.

(* Every evaluation (a /healthz or /metrics request) also counts the streams that went
   from fresh to stale since the previous one. *)
let health ?(max_age = default_max_age) t =
  let stale =
    List.filter_map (sorted t) ~f:(fun (key, c) ->
      if not c.raw
      then None
      else (
        let last_frame_age = age t c in
        let stale = Time_ns.Span.( > ) last_frame_age max_age in
        if stale && not c.stale then c.flaps <- c.flaps + 1;
        c.stale <- stale;
        if stale then Some { Health.key; last_frame_age; frames = c.frames } else None))
  in
  if List.is_empty stale then Health.Healthy else Stale stale
;;

module Stream_status = struct
  type t =
    { key : Key.t
    ; frames : int
    ; bytes : int
    ; events : int
    ; clamped : int
    ; flaps : int
    ; last_frame_age : Time_ns.Span.t
    }
  [@@deriving sexp_of]
end

let streams t =
  List.map (sorted t) ~f:(fun (key, c) ->
    { Stream_status.key
    ; frames = c.frames
    ; bytes = c.bytes
    ; events = c.events
    ; clamped = c.clamped
    ; flaps = c.flaps
    ; last_frame_age = age t c
    })
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
  ignore (health t : Health.t);
  let buf = Buffer.create 1024 in
  let rows = sorted t in
  let family ?(raw_only = false) name ~type_ ~help value =
    bprintf buf "# HELP %s %s\n# TYPE %s %s\n" name help name type_;
    List.iter rows ~f:(fun (key, (c : Counters.t)) ->
      if c.raw || not raw_only then bprintf buf "%s%s %s\n" name (labels key) (value c))
  in
  family
    ~raw_only:true
    "market_recorder_frames_total"
    ~type_:"counter"
    ~help:"Raw frames received."
    (fun c -> Int.to_string c.frames);
  family
    ~raw_only:true
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
    ~raw_only:true
    "market_recorder_clamped_frames_total"
    ~type_:"counter"
    ~help:"Raw frames whose recv_ts went backwards and was raised to the previous one."
    (fun c -> Int.to_string c.clamped);
  family
    "market_recorder_norm_pipe_length"
    ~type_:"gauge"
    ~help:"Normalized events waiting in the pipe to the event log writer."
    (fun c -> Int.to_string (c.pipe_length ()));
  family
    ~raw_only:true
    "market_recorder_healthz_flaps_total"
    ~type_:"counter"
    ~help:"Times the stream went stale (no frame for 30s) after being fresh."
    (fun c -> Int.to_string c.flaps);
  family
    ~raw_only:true
    "market_recorder_last_frame_age_seconds"
    ~type_:"gauge"
    ~help:"Seconds since the last raw frame (since start if none yet)."
    (fun c -> sprintf "%.3f" (Time_ns.Span.to_sec (age t c)));
  let per_venue = feed_stats t in
  let venue_family name ~help value =
    if not (List.is_empty per_venue)
    then (
      bprintf buf "# HELP %s %s\n# TYPE %s counter\n" name help name;
      List.iter per_venue ~f:(fun (venue, stats) ->
        bprintf
          buf
          "%s{venue=\"%s\"} %d\n"
          name
          (Market_data.Venue.to_string venue)
          (value stats)))
  in
  venue_family
    "market_recorder_client_frames_total"
    ~help:"Websocket text frames the venue clients received, acks included."
    (fun (s : Feed_stats.t) -> s.frames);
  venue_family
    "market_recorder_parse_errors_total"
    ~help:"Frames the venue clients dropped as undecodable or error responses."
    (fun (s : Feed_stats.t) -> s.parse_errors);
  venue_family
    "market_recorder_reconnects_total"
    ~help:"Successful websocket reconnections of the venue clients."
    (fun (s : Feed_stats.t) -> s.reconnects);
  if not (List.is_empty t.lags)
  then (
    let name = "market_recorder_exchange_lag_seconds" in
    bprintf
      buf
      "# HELP %s recv_ts - exch_ts of the venue's latest event with an exchange time.\n\
       # TYPE %s gauge\n"
      name
      name;
    List.iter t.lags ~f:(fun (venue, lag) ->
      bprintf
        buf
        "%s{venue=\"%s\"} %.6f\n"
        name
        (Market_data.Venue.to_string venue)
        (Time_ns.Span.to_sec lag)));
  List.iter t.scalars ~f:(fun (name, type_, help, f) ->
    Option.iter (f ()) ~f:(fun v ->
      bprintf
        buf
        "# HELP %s %s\n# TYPE %s %s\n%s %s\n"
        name
        help
        name
        type_
        name
        (Float.to_string_hum ~decimals:9 ~strip_zero:true v)));
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
