(** Records live market data from Hyperliquid, Binance and Bybit: raw frames in
    Tardis-compatible minute files, normalized events in daily event logs. *)

module Config = Config
module Raw_writer = Raw_writer
module Norm_writer = Norm_writer
module Uploader = Uploader
module Metrics = Metrics
module Process_metrics = Process_metrics
module Warnings = Warnings
module Recorder = Recorder
module Http_server = Http_server
module Status_table = Status_table

(** [rebuild-norm] with every venue's normalizer. *)
module Rebuild = Rebuild

(** [merge]: two collectors' raw minute files into one canonical copy. *)
module Raw_merge = Raw_merge

(** Venue sequence numbers in raw frames, for the merge. *)
module Venue_seq = Venue_seq

(** Exact gaps in a venue sequence. *)
module Seq_gaps = Seq_gaps
