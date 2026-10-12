(** [rebuild-norm] for every venue the recorder records: rebuilds a day of [norm/] event
    logs from the raw minute files with {!Market_data.Rebuild_norm}, linking the
    [Market_data.Normalizer.S] adapter of each client and feed library. *)

open! Core
open! Async

(** One adapter per venue: Hyperliquid, Binance, Bybit, OKX, Coinbase, Kraken, Deribit and
    Bitget. *)
val normalizers : Market_data.Normalizer.t list

(** Rebuilds [date] from [<data_dir>/raw] into [out_dir] (new or empty). With [venues],
    only those venues' raw series are read. *)
val run
  :  ?venues:Market_data.Venue.t list
  -> data_dir:string
  -> out_dir:string
  -> Date.t
  -> Market_data.Rebuild_norm.Stats.t Or_error.t Deferred.t

val command : Command.t
