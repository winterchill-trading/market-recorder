(** Recorder configuration, read from a sexp file:

    {v
((data_dir /var/lib/market-recorder)
 (http_port 9100)
 (venues
  (((venue Binance) (symbols (BTCUSDT ETHUSDT)) (streams (Trades Bbo L2 Funding))
    (config Mainnet))
   ((venue Hyperliquid) (symbols (BTC)) (streams (Trades L2)) (config (Local (port 3000))))))
 (upload
  ((command (rclone copyto {file} remote:bucket/{rel}))
   (delete_after_upload true))))
    v} *)

open! Core

(** Which deployment of a venue to connect to. *)
module Endpoint : sig
  type t =
    | Mainnet
    | Testnet
    | Local of { port : int option [@sexp.option] }
    (** the simulator on localhost, on its default port unless given *)
    | Custom of
        { base_url : string
        ; ws_url : string option [@sexp.option]
        (** derived from [base_url] by the client when absent; the websocket-only venues
            (OKX, Coinbase, Kraken spot, Deribit, Bitget) connect to [ws_url] when given
            and to [base_url] otherwise *)
        ; futures_ws_url : string option [@sexp.option]
        (** Kraken only: the futures websocket that carries funding (mainnet when absent) *)
        }
  [@@deriving sexp, compare, equal]

  (** Why a venue cannot use this endpoint, e.g. [Local] for a venue without a simulator,
      [Testnet] for a venue without a public testnet, or any endpoint of a venue with no
      live feed. *)
  val problem : t -> Market_data.Venue.t -> string option

  val hyperliquid : t -> Hl_client.Config.t
  val binance : t -> Binance_client.Config.t
  val bybit : t -> Bybit_client.Config.t

  (** The functions below raise when {!problem} is [Some _]; {!Config.of_sexp} rejects
      those combinations. [Testnet] is the demo trading endpoint on OKX and
      [test.deribit.com] on Deribit. *)

  val okx : t -> Okx_feed.Config.t
  val coinbase : t -> Coinbase_feed.Config.t
  val kraken : t -> Kraken_feed.Config.t
  val deribit : t -> Deribit_feed.Config.t
  val bitget : t -> Bitget_feed.Config.t
end

module Venue_entry : sig
  type t =
    { venue : Market_data.Venue.t
    ; symbols : string list (** venue names, e.g. [BTCUSDT] or [BTC] *)
    ; streams : Market_data.Stream.t list (** [Private] is rejected *)
    ; config : Endpoint.t [@default Mainnet]
    }
  [@@deriving sexp, compare, equal]
end

module Upload : sig
  type t =
    { command : string list
    (** program and arguments; [{file}] is replaced by the absolute path of the closed
        file and [{rel}] by its path relative to [data_dir] *)
    ; delete_after_upload : bool [@default false]
    }
  [@@deriving sexp, compare, equal]
end

type t =
  { data_dir : string
  ; http_port : int [@default 9100]
  ; venues : Venue_entry.t list
  ; upload : Upload.t option [@sexp.option]
  }
[@@deriving sexp, compare, equal]

(** Parses and validates: at least one venue, every venue with symbols and streams, no
    [Private] stream, an endpoint the venue has ({!Endpoint.problem}), a non-empty upload
    command, and no stream the venue can never deliver (it would keep [/healthz] at 503):
    no [Funding] on Coinbase (spot) or on the Hyperliquid simulator, [Funding] only for
    [-SWAP] symbols on OKX and [-PERPETUAL] symbols on Deribit, and Kraken symbols that
    map to a spot pair (for [Trades], [Bbo], [L2]) and to a futures perpetual (for
    [Funding]). *)
val of_sexp : Sexp.t -> t Or_error.t

val load : string -> t Or_error.t
