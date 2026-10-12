open! Core
open! Async

module Status = struct
  type t =
    { open_minute_files : string list
    ; pending_uploads : string list
    ; streams : Metrics.Stream_status.t list
    ; clients : (Market_data.Venue.t * Metrics.Feed_stats.t) list
    }
  [@@deriving sexp_of]

  let create ~open_minute_files ~pending_uploads metrics =
    { open_minute_files
    ; pending_uploads
    ; streams = Metrics.streams metrics
    ; clients = Metrics.feed_stats metrics
    }
  ;;
end

type t =
  { data_dir : string
  ; raw : Raw_writer.t
  ; norm : Norm_writer.t
  ; uploader : Uploader.t option
  ; metrics : Metrics.t
  ; feeds : Market_data.Feed.t list
  ; consumed : unit Deferred.t
  ; seen : Metrics.Key.t Hash_set.t
  ; mutable stopping : unit Deferred.t option
  }

let metrics t = t.metrics

let status t =
  let relative = List.map ~f:(Uploader.relative ~data_dir:t.data_dir) in
  Status.create
    ~open_minute_files:(relative (Raw_writer.open_files t.raw))
    ~pending_uploads:
      (relative (Option.value_map t.uploader ~default:[] ~f:Uploader.pending))
    t.metrics
;;

let stats (frames, parse_errors, reconnects) =
  { Metrics.Feed_stats.frames; parse_errors; reconnects }
;;

(* A feed with its gaps (none from the feeds that do not report them yet) and a reader of
   its client's counters. Error frames the server sends count as parse errors, as they do
   in the clients that do not count them apart. *)
let open_feed (entry : Config.Venue_entry.t) ~symbol ~on_raw =
  let symbols = [ symbol ] in
  let streams = entry.streams in
  match entry.venue with
  | Hyperliquid ->
    let%map t =
      Hl_client.Live_feed.start
        ~on_raw
        (Config.Endpoint.hyperliquid entry.config)
        ~symbols
        ~streams
    in
    ( Hl_client.Live_feed.feed_with_gaps t
    , fun () ->
        let { Hl_client.Live_feed.Stats.frames; parse_errors; error_frames; reconnects } =
          Hl_client.Live_feed.stats t
        in
        stats (frames, parse_errors + error_frames, reconnects) )
  | Binance ->
    let%map t =
      Binance_client.Live_feed.start
        ~on_raw
        (Config.Endpoint.binance entry.config)
        ~symbols
        ~streams
    in
    ( Binance_client.Live_feed.feed_with_gaps t
    , fun () ->
        let { Binance_client.Live_feed.Stats.frames; parse_errors; reconnects } =
          Binance_client.Live_feed.stats t
        in
        stats (frames, parse_errors, reconnects) )
  | Bybit ->
    let%map t =
      Bybit_client.Live_feed.connect
        ~on_raw
        (Bybit_client.Config.read_only (Config.Endpoint.bybit entry.config))
        ~symbols
        ~streams
    in
    ( Bybit_client.Live_feed.feed_with_gaps t
    , fun () ->
        List.fold
          (Bybit_client.Live_feed.stats t)
          ~init:Metrics.Feed_stats.zero
          ~f:(fun sum (_, { frames; parse_errors; reconnects }) ->
            Metrics.Feed_stats.( + ) sum (stats (frames, parse_errors, reconnects))) )
  | Okx ->
    let%map t =
      Okx_feed.Live_feed.start
        ~on_raw
        (Config.Endpoint.okx entry.config)
        ~symbols
        ~streams
    in
    ( Okx_feed.Live_feed.feed_with_gaps t
    , fun () ->
        let { Okx_feed.Live_feed.Stats.frames; parse_errors; reconnects } =
          Okx_feed.Live_feed.stats t
        in
        stats (frames, parse_errors, reconnects) )
  | Coinbase ->
    let%map t =
      Coinbase_feed.Live_feed.start
        ~on_raw
        (Config.Endpoint.coinbase entry.config)
        ~symbols
        ~streams
    in
    ( Coinbase_feed.Live_feed.feed_with_gaps t
    , fun () ->
        let { Coinbase_feed.Live_feed.Stats.frames; parse_errors; reconnects } =
          Coinbase_feed.Live_feed.stats t
        in
        stats (frames, parse_errors, reconnects) )
  | Kraken ->
    let%map t =
      Kraken_feed.Live_feed.start
        ~on_raw
        (Config.Endpoint.kraken entry.config)
        ~symbols
        ~streams
    in
    ( Market_data.Feed.With_gaps.of_feed (Kraken_feed.Live_feed.feed t)
    , fun () ->
        let { Kraken_feed.Live_feed.Stats.frames; parse_errors; reconnects } =
          Kraken_feed.Live_feed.stats t
        in
        stats (frames, parse_errors, reconnects) )
  | Deribit ->
    let%map t =
      Deribit_feed.Live_feed.start
        ~on_raw
        (Config.Endpoint.deribit entry.config)
        ~symbols
        ~streams
    in
    ( Deribit_feed.Live_feed.feed_with_gaps t
    , fun () ->
        let { Deribit_feed.Live_feed.Stats.frames; parse_errors; reconnects } =
          Deribit_feed.Live_feed.stats t
        in
        stats (frames, parse_errors, reconnects) )
  | Bitget ->
    let%map feed, read =
      Bitget_feed.Live_feed.create_with_stats
        ~on_raw
        (Config.Endpoint.bitget entry.config)
        ~symbols
        ~streams
    in
    ( Market_data.Feed.With_gaps.of_feed feed
    , fun () ->
        let { Bitget_feed.Live_feed.Stats.frames; parse_errors; error_events; reconnects }
          =
          read ()
        in
        stats (frames, parse_errors + error_events, reconnects) )
  | (Nyse | Cboe | Cme) as venue ->
    (* rejected by [Config.of_sexp] *)
    raise_s [%message "no live feed" (venue : Market_data.Venue.t)]
;;

let record_gaps ~raw ~metrics ~is_open ~venue ~symbol ~streams gaps =
  Pipe.iter_without_pushback gaps ~f:(fun (gap : Market_data.Gap.t) ->
    let affected =
      match gap.instrument with
      | Some i ->
        Market_data.Instrument.equal i (Market_data.Instrument.create venue symbol)
      | None -> true
    in
    if affected
    then
      List.iter streams ~f:(fun stream ->
        if Option.for_all gap.stream ~f:(Market_data.Stream.equal stream)
        then (
          let key = { Metrics.Key.venue; stream; symbol } in
          Metrics.gap metrics key;
          if is_open key
          then Raw_writer.disconnect raw ~venue ~stream ~symbol ~recv_ts:gap.recv_ts)))
;;

(* Hyperliquid's [l2Book] frames feed both [L2] and [Bbo]; the client passes each one to
   [on_raw] once, under [L2] when [L2] is requested. *)
let has_raw_frames (entry : Config.Venue_entry.t) (stream : Market_data.Stream.t) =
  match entry.venue, stream with
  | Hyperliquid, Bbo -> not (List.mem entry.streams L2 ~equal:Market_data.Stream.equal)
  | _ -> true
;;

let start ?collector (config : Config.t) =
  let data_dir = config.data_dir in
  let%bind () = Unix.mkdir ~p:() data_dir in
  let%bind uploader =
    match config.upload with
    | None -> return None
    | Some upload -> Uploader.create ~data_dir upload >>| Option.some
  in
  let on_closed file = Option.iter uploader ~f:(fun u -> Uploader.enqueue u file) in
  let%bind recovered = Raw_writer.recover ~data_dir ~on_closed in
  if not (List.is_empty recovered)
  then
    Log.Global.info_s
      [%message
        "compressed files left by an earlier run" ~count:(List.length recovered : int)];
  let warnings = Warnings.create () in
  let raw =
    Raw_writer.create
      ?collector
      ~data_dir
      ~on_closed
      ~on_error:(fun ~venue ~stream ~symbol error ->
        Warnings.warn
          warnings
          { venue; stream; symbol }
          [%message "raw writer failed" (error : Error.t)])
      ()
  in
  let norm =
    Norm_writer.create ~snapshot_interval:config.snapshot_interval ~data_dir ()
  in
  let metrics = Metrics.create () in
  Metrics.set_flush_error_source metrics (fun () -> Raw_writer.last_error raw);
  Option.iter uploader ~f:(fun u ->
    Metrics.set_upload_source metrics (fun () ->
      Uploader.uploaded u, Uploader.failures u, List.length (Uploader.pending u)));
  let seen = Hash_set.create (module Metrics.Key) in
  let%map feeds =
    Deferred.List.concat_map ~how:`Sequential config.venues ~f:(fun entry ->
      Deferred.List.map ~how:`Sequential entry.symbols ~f:(fun symbol ->
        let key stream = { Metrics.Key.venue = entry.venue; stream; symbol } in
        List.iter entry.streams ~f:(fun stream ->
          Metrics.register ~raw:(has_raw_frames entry stream) metrics (key stream));
        let on_raw ~stream ~recv_ts frame =
          let key = key stream in
          let clamped = Metrics.clamp_recv_ts metrics key recv_ts in
          if not (Time_ns.equal clamped recv_ts)
          then
            Warnings.warn
              warnings
              key
              [%message
                "recv_ts went backwards" (recv_ts : Time_ns.t) (clamped : Time_ns.t)];
          let recv_ts = clamped in
          Hash_set.add seen key;
          Metrics.frame metrics key ~recv_ts ~bytes:(String.length frame);
          Raw_writer.write raw ~venue:entry.venue ~stream ~symbol ~recv_ts frame
        in
        let%map with_gaps, read_stats = open_feed entry ~symbol ~on_raw in
        Metrics.add_feed_stats_source metrics ~venue:entry.venue read_stats;
        let (module G : Market_data.Feed.With_gaps.S) = with_gaps in
        don't_wait_for
          (record_gaps
             ~raw
             ~metrics
             ~is_open:(Hash_set.mem seen)
             ~venue:entry.venue
             ~symbol
             ~streams:(List.filter entry.streams ~f:(has_raw_frames entry))
             G.gaps);
        let feed = Market_data.Feed.With_gaps.to_feed with_gaps in
        let (module F : Market_data.Feed.S) = feed in
        List.iter entry.streams ~f:(fun stream ->
          let length : Market_data.Stream.t -> unit -> int = function
            | Trades -> fun () -> Pipe.length F.trades
            | Bbo -> fun () -> Pipe.length F.bbo
            | L2 -> fun () -> Pipe.length F.l2
            | Funding -> fun () -> Pipe.length F.funding
            | Private -> fun () -> 0
          in
          Metrics.set_pipe_length metrics (key stream) (length stream));
        Log.Global.info_s
          [%message
            "recording"
              ~venue:(entry.venue : Market_data.Venue.t)
              (symbol : string)
              ~streams:(entry.streams : Market_data.Stream.t list)];
        ( feed
        , Norm_writer.consume norm feed ~on_event:(fun event ->
            let stream = Market_data.Event.stream event in
            Metrics.event metrics (key stream);
            (* funding carries no exchange time on some venues *)
            match stream with
            | Funding -> ()
            | Trades | Bbo | L2 | Private ->
              Metrics.exchange_lag
                metrics
                ~venue:entry.venue
                (Time_ns.diff
                   (Market_data.Event.recv_ts event)
                   (Market_data.Event.exch_ts event))) )))
  in
  { data_dir
  ; raw
  ; norm
  ; uploader
  ; metrics
  ; feeds = List.map feeds ~f:fst
  ; consumed = Deferred.all_unit (List.map feeds ~f:snd)
  ; seen
  ; stopping = None
  }
;;

let stop_now t =
  let%bind () =
    Deferred.List.iter ~how:`Parallel t.feeds ~f:(fun (module F : Market_data.Feed.S) ->
      F.close ())
  in
  let%bind (_ : unit Clock_ns.Or_timeout.t) =
    Clock_ns.with_timeout (Time_ns.Span.of_sec 5.) t.consumed
  in
  let recv_ts = Time_ns.now () in
  Hash_set.iter t.seen ~f:(fun { venue; stream; symbol } ->
    Raw_writer.disconnect t.raw ~venue ~stream ~symbol ~recv_ts);
  let%bind () = Raw_writer.close t.raw in
  let%bind () = Norm_writer.close t.norm in
  match t.uploader with
  | None -> return ()
  | Some u ->
    (* give the files of the last minutes a chance to go out; the rest is saved *)
    let%bind (_ : unit Clock_ns.Or_timeout.t) =
      Clock_ns.with_timeout (Time_ns.Span.of_sec 10.) (Uploader.idle u)
    in
    Uploader.close u
;;

let stop t =
  match t.stopping with
  | Some d -> d
  | None ->
    let d = stop_now t in
    t.stopping <- Some d;
    d
;;
