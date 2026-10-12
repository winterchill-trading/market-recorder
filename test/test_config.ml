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
