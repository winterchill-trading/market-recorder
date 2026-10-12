(** Records live market data from Hyperliquid, Binance and Bybit: raw frames in
    Tardis-compatible minute files, normalized events in daily event logs. *)

module Config = Config
module Raw_writer = Raw_writer
module Norm_writer = Norm_writer
module Uploader = Uploader
module Metrics = Metrics
module Recorder = Recorder
module Http_server = Http_server
