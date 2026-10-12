;; Records the three local simulators. Start them with
;;   hl-sim -port 3510, binance-sim -port 3520, bybit-sim -port 3530
;; The upload command copies closed files to a local "remote" directory.
((data_dir /tmp/market-recorder-sims/data)
 (http_port 9910)
 (venues
  (((venue Hyperliquid)
    (symbols (BTC ETH))
    (streams (Trades Bbo L2))
    (config (Local (port 3510))))
   ((venue Binance)
    (symbols (BTCUSDT ETHUSDT))
    (streams (Trades Bbo L2 Funding))
    (config (Local (port 3520))))
   ((venue Bybit)
    (symbols (BTCUSDT ETHUSDT))
    (streams (Trades Bbo L2 Funding))
    (config (Local (port 3530))))))
 (upload
  ((command
    (sh -c "mkdir -p \"$(dirname \"$2\")\" && cp \"$1\" \"$2\"" sh {file}
     /tmp/market-recorder-sims/remote/{rel}))
   (delete_after_upload false))))
