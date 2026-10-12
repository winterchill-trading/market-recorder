open! Core
open! Async

type t =
  { raw : Raw_writer.t
  ; norm : Norm_writer.t
  ; uploader : Uploader.t option
  ; metrics : Metrics.t
  ; feeds : Market_data.Feed.t list
  ; consumed : unit Deferred.t
  ; seen : Metrics.Key.t Hash_set.t
  ; mutable stopping : unit Deferred.t option
  }

let metrics t = t.metrics

let open_feed (entry : Config.Venue_entry.t) ~symbol ~on_raw =
  let symbols = [ symbol ] in
  let streams = entry.streams in
  match entry.venue with
  | Hyperliquid ->
    Hl_client.Live_feed.create
      ~on_raw
      (Config.Endpoint.hyperliquid entry.config)
      ~symbols
      ~streams
  | Binance ->
    Binance_client.Live_feed.create
      ~on_raw
      (Config.Endpoint.binance entry.config)
      ~symbols
      ~streams
  | Bybit ->
    Bybit_client.Live_feed.create
      ~on_raw
      (Config.Endpoint.bybit entry.config)
      ~symbols
      ~streams
  | Okx ->
    Okx_feed.Live_feed.create ~on_raw (Config.Endpoint.okx entry.config) ~symbols ~streams
  | Coinbase ->
    Coinbase_feed.Live_feed.create
      ~on_raw
      (Config.Endpoint.coinbase entry.config)
      ~symbols
      ~streams
  | Kraken ->
    Kraken_feed.Live_feed.create
      ~on_raw
      (Config.Endpoint.kraken entry.config)
      ~symbols
      ~streams
  | Deribit ->
    Deribit_feed.Live_feed.create
      ~on_raw
      (Config.Endpoint.deribit entry.config)
      ~symbols
      ~streams
  | Bitget ->
    Bitget_feed.Live_feed.create
      ~on_raw
      (Config.Endpoint.bitget entry.config)
      ~symbols
      ~streams
  | (Nyse | Cboe | Cme) as venue ->
    (* rejected by [Config.of_sexp] *)
    raise_s [%message "no live feed" (venue : Market_data.Venue.t)]
;;

let start (config : Config.t) =
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
      ~data_dir
      ~on_closed
      ~on_error:(fun ~venue ~stream ~symbol error ->
        Warnings.warn
          warnings
          { venue; stream; symbol }
          [%message "raw writer failed" (error : Error.t)])
      ()
  in
  let norm = Norm_writer.create ~data_dir () in
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
        List.iter entry.streams ~f:(fun stream -> Metrics.register metrics (key stream));
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
        let%map feed = open_feed entry ~symbol ~on_raw in
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
            Metrics.event metrics (key (Market_data.Event.stream event))) )))
  in
  { raw
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
