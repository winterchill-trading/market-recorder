open! Core

module Endpoint = struct
  type t =
    | Mainnet
    | Testnet
    | Local of { port : int option [@sexp.option] }
    | Custom of
        { base_url : string
        ; ws_url : string option [@sexp.option]
        ; futures_ws_url : string option [@sexp.option]
        }
  [@@deriving sexp, compare, equal]

  let ws_url = Option.map ~f:Uri.of_string

  let hyperliquid = function
    | Mainnet -> Hl_client.Config.mainnet ()
    | Testnet -> Hl_client.Config.testnet ()
    | Local { port = None } -> Hl_client.Config.local ()
    | Local { port = Some port } ->
      Hl_client.Config.create
        ~base_url:(Uri.of_string (sprintf "http://localhost:%d" port))
        ()
    | Custom { base_url; ws_url = w; futures_ws_url = _ } ->
      Hl_client.Config.create ?ws_url:(ws_url w) ~base_url:(Uri.of_string base_url) ()
  ;;

  (* Public market streams need no key; the simulator wants some account name. *)
  let binance = function
    | Mainnet -> Binance_client.Config.mainnet ~api_key:"" ~api_secret:"" ()
    | Testnet -> Binance_client.Config.testnet ~api_key:"" ~api_secret:"" ()
    | Local { port } -> Binance_client.Config.local ?port ~api_key:"market-recorder" ()
    | Custom { base_url; ws_url = w; futures_ws_url = _ } ->
      Binance_client.Config.create
        ?ws_url:(ws_url w)
        ~base_url:(Uri.of_string base_url)
        ~api_key:""
        ()
  ;;

  let bybit = function
    | Mainnet -> Bybit_client.Config.mainnet ()
    | Testnet -> Bybit_client.Config.testnet ()
    | Local { port } -> Bybit_client.Config.local ?port ()
    | Custom { base_url; ws_url = w; futures_ws_url = _ } ->
      Bybit_client.Config.create
        ?ws_public_url:(ws_url w)
        ~base_url:(Uri.of_string base_url)
        ()
  ;;

  (* The websocket-only feeds take one URL: [ws_url] when given, else [base_url]. *)
  let custom_url ~base_url ~ws_url = Uri.of_string (Option.value ws_url ~default:base_url)
  let okx_demo_url = Uri.of_string "wss://wspap.okx.com:8443/ws/v5/public"

  let problem t (venue : Market_data.Venue.t) =
    match venue, t with
    | (Hyperliquid | Binance | Bybit), _ -> None
    | (Okx | Coinbase | Kraken | Deribit | Bitget), Local _ ->
      Some "no simulator, use Mainnet or Custom"
    | (Coinbase | Kraken | Bitget), Testnet ->
      Some "no public testnet, use Mainnet or Custom"
    | (Okx | Deribit), Testnet
    | (Okx | Coinbase | Kraken | Deribit | Bitget), (Mainnet | Custom _) -> None
    | (Nyse | Cboe | Cme), _ -> Some "no live feed for this venue"
  ;;

  let unsupported venue t =
    raise_s
      [%message
        "unsupported endpoint"
          (venue : Market_data.Venue.t)
          ~endpoint:(t : t)
          ~reason:(Option.value (problem t venue) ~default:"" : string)]
  ;;

  let okx = function
    | Mainnet -> Okx_feed.Config.mainnet
    | Testnet -> Okx_feed.Config.create ~url:okx_demo_url ()
    | Custom { base_url; ws_url; _ } ->
      Okx_feed.Config.create ~url:(custom_url ~base_url ~ws_url) ()
    | Local _ as t -> unsupported Okx t
  ;;

  let coinbase = function
    | Mainnet -> Coinbase_feed.Config.mainnet
    | Custom { base_url; ws_url; _ } ->
      Coinbase_feed.Config.create ~url:(custom_url ~base_url ~ws_url) ()
    | (Testnet | Local _) as t -> unsupported Coinbase t
  ;;

  let kraken = function
    | Mainnet -> Kraken_feed.Config.mainnet
    | Custom { base_url; ws_url; futures_ws_url } ->
      Kraken_feed.Config.create
        ~spot_url:(custom_url ~base_url ~ws_url)
        ?futures_url:(Option.map futures_ws_url ~f:Uri.of_string)
        ()
    | (Testnet | Local _) as t -> unsupported Kraken t
  ;;

  let deribit = function
    | Mainnet -> Deribit_feed.Config.mainnet
    | Testnet -> Deribit_feed.Config.testnet
    | Custom { base_url; ws_url; _ } ->
      Deribit_feed.Config.create ~url:(custom_url ~base_url ~ws_url) ()
    | Local _ as t -> unsupported Deribit t
  ;;

  let bitget = function
    | Mainnet -> Bitget_feed.Config.create ()
    | Custom { base_url; ws_url; _ } ->
      Bitget_feed.Config.create ~url:(custom_url ~base_url ~ws_url) ()
    | (Testnet | Local _) as t -> unsupported Bitget t
  ;;
end

module Venue_entry = struct
  type t =
    { venue : Market_data.Venue.t
    ; symbols : string list
    ; streams : Market_data.Stream.t list
    ; config : Endpoint.t [@default Mainnet]
    }
  [@@deriving sexp, compare, equal]
end

module Upload = struct
  type t =
    { command : string list
    ; delete_after_upload : bool [@default false]
    }
  [@@deriving sexp, compare, equal]
end

type t =
  { data_dir : string
  ; http_port : int [@default 9100]
  ; venues : Venue_entry.t list
  ; upload : Upload.t option [@sexp.option]
  ; snapshot_interval : Time_ns.Span.t
       [@default Time_ns.Span.of_min 1.] [@sexp_drop_default Time_ns.Span.equal]
  }
[@@deriving sexp, compare, equal]

let has_stream (v : Venue_entry.t) stream =
  List.mem v.streams stream ~equal:Market_data.Stream.equal
;;

let symbols_failing (v : Venue_entry.t) ~f =
  List.filter v.symbols ~f:(fun symbol -> not (f symbol))
;;

let maps ~f symbol = Result.is_ok (Result.try_with (fun () -> f symbol))

(* Streams a venue entry asks for but can never deliver: such a stream would hold /healthz
   at 503 forever (or, on Kraken, make the feed raise at start). *)
let stream_problems (v : Venue_entry.t) =
  let funding = has_stream v Funding in
  let needs_suffix suffix kind =
    if not funding
    then []
    else
      symbols_failing v ~f:(String.is_suffix ~suffix)
      |> List.map ~f:(fun symbol ->
        sprintf "Funding needs %s (symbols ending in %s), not %s" kind suffix symbol)
  in
  match v.venue with
  | Coinbase when funding ->
    [ "Funding is not available (spot only, no funding channel)" ]
  | Hyperliquid ->
    (match v.config with
     | Local _ when funding -> [ "Funding is not served by the simulator (Local)" ]
     | Local _ | Mainnet | Testnet | Custom _ -> [])
  | Okx -> needs_suffix "-SWAP" "perpetual swaps"
  | Deribit -> needs_suffix "-PERPETUAL" "perpetuals"
  | Kraken ->
    let spot_streams =
      List.exists v.streams ~f:(function
        | Trades | Bbo | L2 -> true
        | Funding | Private -> false)
    in
    List.concat
      [ (if spot_streams
         then
           symbols_failing v ~f:(maps ~f:Kraken_feed.Symbols.spot)
           |> List.map ~f:(sprintf "%s has no spot name (use BTC/USD or PF_XBTUSD)")
         else [])
      ; (if funding
         then
           symbols_failing v ~f:(maps ~f:Kraken_feed.Symbols.futures)
           |> List.map ~f:(sprintf "%s has no futures perpetual for Funding")
         else [])
      ]
  | Binance | Bybit | Coinbase | Bitget | Nyse | Cboe | Cme -> []
;;

let validate t =
  let errors =
    List.concat
      [ (if List.is_empty t.venues then [ "no venues" ] else [])
      ; List.concat_map t.venues ~f:(fun (v : Venue_entry.t) ->
          let name = Market_data.Venue.to_string v.venue in
          List.concat
            [ (if List.is_empty v.symbols then [ name ^ ": no symbols" ] else [])
            ; (if List.is_empty v.streams then [ name ^ ": no streams" ] else [])
            ; (if has_stream v Private
               then [ name ^ ": Private streams cannot be recorded" ]
               else [])
            ; (match Endpoint.problem v.config v.venue with
               | Some reason ->
                 [ sprintf
                     "%s: endpoint %s: %s"
                     name
                     (Sexp.to_string (Endpoint.sexp_of_t v.config))
                     reason
                 ]
               | None -> List.map (stream_problems v) ~f:(fun p -> name ^ ": " ^ p))
            ])
      ; (match t.upload with
         | Some { command = []; _ } -> [ "upload: empty command" ]
         | _ -> [])
      ; (if Time_ns.Span.( < ) t.snapshot_interval Time_ns.Span.zero
         then [ "snapshot_interval: negative" ]
         else [])
      ]
  in
  match errors with
  | [] -> Ok t
  | errors -> Or_error.error_s [%message "invalid config" (errors : string list)]
;;

let of_sexp sexp =
  Or_error.try_with (fun () -> t_of_sexp sexp) |> Or_error.bind ~f:validate
;;

let load path =
  Or_error.try_with (fun () -> Sexp.load_sexp path)
  |> Or_error.bind ~f:of_sexp
  |> Or_error.tag ~tag:path
;;
