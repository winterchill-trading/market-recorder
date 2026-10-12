(lang dune 3.17)

(name market-recorder)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/market-recorder))

(package
 (name market-recorder)
 (synopsis "Raw-first market data recorder for Hyperliquid, Binance and Bybit")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  cohttp
  cohttp-async
  uri
  zstd
  ppx_jane
  market-data
  hl-client
  binance-client
  bybit-client))
