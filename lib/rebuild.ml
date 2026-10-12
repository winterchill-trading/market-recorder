open! Core
open! Async
module Venue = Market_data.Venue

let normalizers : Market_data.Normalizer.t list =
  [ (module Hl_client.Raw_normalizer)
  ; (module Binance_client.Raw_normalizer)
  ; (module Bybit_client.Raw_normalizer)
  ; Okx_feed.Md_normalizer.normalizer
  ; (module Coinbase_feed.Raw_normalizer)
  ; (module Kraken_feed.Raw_normalizer)
  ; (module Deribit_feed.Rebuild_normalizer)
  ; (module Bitget_feed.Raw_normalizer)
  ]
;;

let run ?venues ~data_dir ~out_dir date =
  let normalizers =
    match venues with
    | None -> normalizers
    | Some venues ->
      List.filter normalizers ~f:(fun n ->
        List.mem venues (Market_data.Normalizer.venue n) ~equal:Venue.equal)
  in
  Market_data.Rebuild_norm.run ~normalizers ~data_dir ~out_dir date
;;

let venue_arg =
  Command.Arg_type.create (fun s ->
    match Venue.of_string_opt s with
    | Some v -> v
    | None -> raise_s [%message "unknown venue" s])
;;

let command =
  Command.async_or_error
    ~summary:"Rebuild a day of norm/ event logs from the recorded raw minute files"
    ~readme:(fun () ->
      sprintf
        "Reads <data-dir>/raw/<venue>/<stream>/<symbol>/<YYYY>/<MM>/<DD>/*.ndjson[.zst] \
         and writes <out>/<venue>/<symbol>/norm/<stream>/<date>.bin, the layout the \
         recorder writes under <data-dir>.\n\
         Venues: %s."
        (List.map normalizers ~f:(fun n ->
           Venue.to_string (Market_data.Normalizer.venue n))
         |> String.concat ~sep:", "))
    (let%map_open.Command data_dir =
       flag "-data-dir" (required string) ~doc:"DIR recorder data directory (holds raw/)"
     and out_dir =
       flag
         "-out"
         (required string)
         ~doc:"DIR where to write the event logs (new or empty)"
     and date = flag "-date" (required date) ~doc:"YYYY-MM-DD UTC day to rebuild"
     and venues =
       flag "-venue" (listed venue_arg) ~doc:"VENUE only this venue (repeatable)"
     in
     fun () ->
       let venues = if List.is_empty venues then None else Some venues in
       let%map.Deferred.Or_error stats = run ?venues ~data_dir ~out_dir date in
       Core.print_s [%sexp (stats : Market_data.Rebuild_norm.Stats.t)])
;;
