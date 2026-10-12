;; Records the eight live venues on mainnet, one BTC market each (the perpetual where
;; the venue has one; Coinbase is spot only, so it has no Funding stream). Kraken's
;; trades, bbo and l2 come from the spot pair BTC/USD, its funding from PF_XBTUSD.
;; The upload command copies closed files to a local "remote" directory.
((data_dir /tmp/market-recorder-mainnet/data)
 (http_port 9920)
 (venues
  (((venue Hyperliquid) (symbols (BTC)) (streams (Trades Bbo L2 Funding)))
   ((venue Binance) (symbols (BTCUSDT)) (streams (Trades Bbo L2 Funding)))
   ((venue Bybit) (symbols (BTCUSDT)) (streams (Trades Bbo L2 Funding)))
   ((venue Okx) (symbols (BTC-USDT-SWAP)) (streams (Trades Bbo L2 Funding)))
   ((venue Coinbase) (symbols (BTC-USD)) (streams (Trades Bbo L2)))
   ((venue Kraken) (symbols (PF_XBTUSD)) (streams (Trades Bbo L2 Funding)))
   ((venue Deribit) (symbols (BTC-PERPETUAL)) (streams (Trades Bbo L2 Funding)))
   ((venue Bitget) (symbols (BTCUSDT)) (streams (Trades Bbo L2 Funding)))))
 (upload
  ((command
    (sh -c "mkdir -p \"$(dirname \"$2\")\" && cp \"$1\" \"$2\"" sh {file}
     /tmp/market-recorder-mainnet/remote/{rel}))
   (delete_after_upload false))))
