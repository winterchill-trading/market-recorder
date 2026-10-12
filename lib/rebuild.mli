(** [rebuild-norm] for every venue the recorder records: rebuilds a day of [norm/] event
    logs from the raw minute files with {!Market_data.Rebuild_norm}, linking the
    [Market_data.Normalizer.S] adapter of each client and feed library. *)

open! Core
open! Async

(** One adapter per venue: Hyperliquid, Binance, Bybit, OKX, Coinbase, Kraken, Deribit and
    Bitget. *)
val normalizers : Market_data.Normalizer.t list

(** A raw [(venue, stream)] to leave out, written [venue:stream] (e.g. [binance:l2]). *)
module Skip : sig
  type t =
    { venue : Market_data.Venue.t
    ; stream : Market_data.Stream.t
    }
  [@@deriving sexp_of, equal]

  val of_string : string -> t Or_error.t
  val arg_type : t Command.Arg_type.t
end

(** Rebuilds [date] from [<data_dir>/raw] into [out_dir] (new or empty). With [venues],
    only those venues' raw series are read. Raw streams in [skip] are not read at all: the
    rebuild runs over a temporary directory of symlinks to the other
    [raw/<venue>/<stream>] directories, removed afterwards. A normalizer that emits events
    of several streams from one raw stream (Hyperliquid [l2] gives [bbo] too) still writes
    them; skip the raw stream that carries them.

    With [collector], only that collector's minute files ([<HH>-<MM>.<collector>.ndjson],
    see {!Raw_files}) are read, through a temporary directory of per-file symlinks under
    their plain names; without it, files carrying a collector id are not read. *)
val run
  :  ?venues:Market_data.Venue.t list
  -> ?skip:Skip.t list
  -> ?collector:string
  -> data_dir:string
  -> out_dir:string
  -> Date.t
  -> Market_data.Rebuild_norm.Stats.t Or_error.t Deferred.t

val command : Command.t
