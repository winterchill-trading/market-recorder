(** Prometheus text from [/metrics] as dense tables, for [market-recorder status].

    Samples labelled with [venue], [stream] and [symbol] become one row per stream with a
    column per metric (the [market_recorder_] prefix and [_total] suffix dropped); every
    other sample is listed below as [name{labels} value]. *)

open! Core

module Sample : sig
  type t =
    { name : string
    ; labels : (string * string) list
    ; value : string
    }
  [@@deriving sexp_of]
end

(** Parses the sample lines, skipping comments and blank lines. Malformed lines are an
    error naming the line. *)
val parse : string -> Sample.t list Or_error.t

val render : Sample.t list -> string
