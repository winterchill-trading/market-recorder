open! Core
open Market_recorder

let parse s =
  match Config.of_sexp (Sexp.of_string s) with
  | Ok t -> print_s [%sexp (t : Config.t)]
  | Error e -> print_s [%sexp (e : Error.t)]
;;

let%expect_test "full config round trips" =
  parse
    {|((data_dir /data)
       (http_port 9200)
       (venues
        (((venue Binance) (symbols (BTCUSDT ETHUSDT)) (streams (Trades Bbo L2 Funding))
          (config Mainnet))
         ((venue Hyperliquid) (symbols (BTC)) (streams (Trades L2))
          (config (Local (port 3001))))
         ((venue Bybit) (symbols (BTCUSDT)) (streams (Bbo))
          (config (Custom (base_url https://api.bybit.com))))))
       (upload ((command (rclone copyto {file} remote:bucket/{rel}))
                (delete_after_upload true))))|};
  [%expect
    {|
    ((data_dir /data) (http_port 9200)
     (venues
      (((venue Binance) (symbols (BTCUSDT ETHUSDT))
        (streams (Trades Bbo L2 Funding)) (config Mainnet))
       ((venue Hyperliquid) (symbols (BTC)) (streams (Trades L2))
        (config (Local (port 3001))))
       ((venue Bybit) (symbols (BTCUSDT)) (streams (Bbo))
        (config (Custom (base_url https://api.bybit.com))))))
     (upload
      ((command (rclone copyto {file} remote:bucket/{rel}))
       (delete_after_upload true))))
    |}]
;;

let%expect_test "defaults" =
  parse {|((data_dir d) (venues (((venue Bybit) (symbols (X)) (streams (Trades))))))|};
  [%expect
    {|
    ((data_dir d) (http_port 9100)
     (venues (((venue Bybit) (symbols (X)) (streams (Trades)) (config Mainnet)))))
    |}]
;;

let%expect_test "validation" =
  parse
    {|((data_dir d)
       (venues (((venue Bybit) (symbols ()) (streams (Trades Private)))
                ((venue Binance) (symbols (A)) (streams ()))))
       (upload ((command ()))))|};
  [%expect
    {|
    ("invalid config"
     (errors
      ("bybit: no symbols" "bybit: Private streams cannot be recorded"
       "binance: no streams" "upload: empty command")))
    |}];
  parse {|((data_dir d) (venues ()))|};
  [%expect {| ("invalid config" (errors ("no venues"))) |}]
;;

let%expect_test "endpoints resolve to client configs" =
  let local = Config.Endpoint.Local { port = Some 3401 } in
  print_s [%sexp (Config.Endpoint.bybit local : Bybit_client.Config.t)];
  print_s
    [%sexp
      (Uri.to_string (Config.Endpoint.hyperliquid local).ws_url : string)
      , (Uri.to_string (Config.Endpoint.binance Mainnet).ws_url : string)];
  [%expect
    {|
    ((base_url http://localhost:3401)
     (ws_public_url ws://localhost:3401/v5/public/linear)
     (ws_private_url ws://localhost:3401/v5/private) (api_key ()) (api_secret ())
     (recv_window 5000))
    (ws://localhost:3401/ws wss://fstream.binance.com)
    |}]
;;

let%expect_test "new venues parse with their endpoints" =
  parse
    {|((data_dir d)
       (venues
        (((venue Okx) (symbols (BTC-USDT-SWAP)) (streams (Trades Bbo L2 Funding)))
         ((venue Coinbase) (symbols (BTC-USD)) (streams (Trades Bbo L2)))
         ((venue Kraken) (symbols (PF_XBTUSD BTC/USD)) (streams (Trades Bbo L2 Funding))
          (config (Custom (base_url ws://localhost:1) (futures_ws_url ws://localhost:2))))
         ((venue Deribit) (symbols (BTC-PERPETUAL)) (streams (Trades Funding))
          (config Testnet))
         ((venue Bitget) (symbols (BTCUSDT)) (streams (Trades Bbo L2 Funding))))))|};
  [%expect
    {|
    ((data_dir d) (http_port 9100)
     (venues
      (((venue Okx) (symbols (BTC-USDT-SWAP)) (streams (Trades Bbo L2 Funding))
        (config Mainnet))
       ((venue Coinbase) (symbols (BTC-USD)) (streams (Trades Bbo L2))
        (config Mainnet))
       ((venue Kraken) (symbols (PF_XBTUSD BTC/USD))
        (streams (Trades Bbo L2 Funding))
        (config
         (Custom (base_url ws://localhost:1) (futures_ws_url ws://localhost:2))))
       ((venue Deribit) (symbols (BTC-PERPETUAL)) (streams (Trades Funding))
        (config Testnet))
       ((venue Bitget) (symbols (BTCUSDT)) (streams (Trades Bbo L2 Funding))
        (config Mainnet)))))
    |}]
;;

let%expect_test "streams and endpoints a venue cannot serve are rejected" =
  parse
    {|((data_dir d)
       (venues
        (((venue Coinbase) (symbols (BTC-USD)) (streams (Trades Funding)))
         ((venue Okx) (symbols (BTC-USDT-SWAP BTC-USDT)) (streams (Funding)))
         ((venue Deribit) (symbols (BTC-27NOV26)) (streams (L2 Funding)))
         ((venue Kraken) (symbols (XBTUSD PF_XBTUSD)) (streams (Trades Funding)))
         ((venue Hyperliquid) (symbols (BTC)) (streams (Funding)) (config (Local)))
         ((venue Bitget) (symbols (BTCUSDT)) (streams (Trades)) (config Testnet))
         ((venue Okx) (symbols (BTC-USDT-SWAP)) (streams (Trades)) (config (Local)))
         ((venue Nyse) (symbols (AAPL)) (streams (Trades))))))|};
  [%expect
    {|
    ("invalid config"
     (errors
      ("coinbase: Funding is not available (spot only, no funding channel)"
       "okx: Funding needs perpetual swaps (symbols ending in -SWAP), not BTC-USDT"
       "deribit: Funding needs perpetuals (symbols ending in -PERPETUAL), not BTC-27NOV26"
       "kraken: XBTUSD has no futures perpetual for Funding"
       "hyperliquid: Funding is not served by the simulator (Local)"
       "bitget: endpoint Testnet: no public testnet, use Mainnet or Custom"
       "okx: endpoint (Local): no simulator, use Mainnet or Custom"
       "nyse: endpoint Mainnet: no live feed for this venue")))
    |}]
;;

let%expect_test "new venue endpoints resolve to feed configs" =
  let custom =
    Config.Endpoint.Custom
      { base_url = "wss://example.test/ws"; ws_url = None; futures_ws_url = None }
  in
  print_s [%sexp (Config.Endpoint.okx Testnet : Okx_feed.Config.t)];
  print_s [%sexp (Config.Endpoint.coinbase custom : Coinbase_feed.Config.t)];
  print_s [%sexp (Config.Endpoint.kraken custom : Kraken_feed.Config.t)];
  print_s [%sexp (Config.Endpoint.deribit Testnet : Deribit_feed.Config.t)];
  print_s [%sexp (Config.Endpoint.bitget Mainnet : Bitget_feed.Config.t)];
  [%expect
    {|
    ((url wss://wspap.okx.com:8443/ws/v5/public))
    ((url wss://example.test/ws))
    ((spot_url wss://example.test/ws)
     (futures_url wss://futures.kraken.com/ws/v1))
    ((url wss://test.deribit.com/ws/api/v2) (interval 100ms))
    ((url wss://ws.bitget.com/v2/ws/public) (inst_type USDT-FUTURES))
    |}]
;;

let%expect_test "every example config parses and validates" =
  let dir = "../examples" in
  Sys_unix.readdir dir
  |> Array.to_list
  |> List.filter ~f:(String.is_suffix ~suffix:".sexp")
  |> List.sort ~compare:String.compare
  |> List.iter ~f:(fun name ->
    match Config.load (dir ^/ name) with
    | Ok (config : Config.t) ->
      print_s
        [%message
          name
            ~venues:(List.length config.venues : int)
            ~streams:
              (List.sum (module Int) config.venues ~f:(fun v ->
                 List.length v.symbols * List.length v.streams)
               : int)]
    | Error e -> print_s [%message name (e : Error.t)]);
  [%expect
    {|
    (mainnet-all.sexp (venues 8) (streams 31))
    (sims.sexp (venues 3) (streams 22))
    |}]
;;
