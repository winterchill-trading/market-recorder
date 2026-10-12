open! Core
open! Async
module Venue = Market_data.Venue
module Md_stream = Market_data.Stream

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

module Skip = struct
  type t =
    { venue : Venue.t
    ; stream : Md_stream.t
    }
  [@@deriving sexp_of, equal]

  let of_string s =
    match String.lsplit2 s ~on:':' with
    | Some (venue, stream) ->
      (match Venue.of_string_opt venue, Md_stream.of_string_opt stream with
       | Some venue, Some stream -> Ok { venue; stream }
       | _ -> Or_error.error_s [%message "unknown venue or stream" s])
    | None -> Or_error.error_s [%message "expected venue:stream" s]
  ;;

  let arg_type = Command.Arg_type.create (fun s -> ok_exn (of_string s))
end

let ls dir =
  match%bind Sys.is_directory_exn dir with
  | false -> return []
  | true ->
    let%map names = Sys.readdir dir in
    Array.to_list names |> List.sort ~compare:String.compare
;;

let skipped skip ~venue ~stream =
  match Venue.of_string_opt venue, Md_stream.of_string_opt stream with
  | Some venue, Some stream -> List.mem skip { Skip.venue; stream } ~equal:Skip.equal
  | _ -> false
;;

(* [f] over a directory whose raw/<venue>/<stream> entries are symlinks to the [data_dir]
   ones not in [skip]. Only the links and the directories made here are removed
   afterwards, never anything they point to. *)
let with_view ~data_dir ~skip f =
  match skip with
  | [] -> f data_dir
  | skip ->
    let%bind data_dir = In_thread.run (fun () -> Filename_unix.realpath data_dir) in
    let%bind view = Unix.mkdtemp (Filename.temp_dir_name ^/ "rebuild-norm") in
    let links = ref []
    and dirs = ref [ view; view ^/ "raw" ] in
    Monitor.protect
      ~finally:(fun () ->
        let%bind () = Deferred.List.iter !links ~how:`Sequential ~f:Unix.unlink in
        Deferred.List.iter !dirs ~how:`Sequential ~f:(fun dir ->
          Monitor.try_with (fun () -> Unix.rmdir dir) |> Deferred.ignore_m))
      (fun () ->
        let%bind () = Unix.mkdir (view ^/ "raw") in
        let raw = data_dir ^/ "raw" in
        let%bind venues = ls raw in
        let%bind () =
          Deferred.List.iter venues ~how:`Sequential ~f:(fun venue ->
            let%bind streams = ls (raw ^/ venue) in
            match
              List.filter streams ~f:(fun stream -> not (skipped skip ~venue ~stream))
            with
            | [] -> return ()
            | streams ->
              let dir = view ^/ "raw" ^/ venue in
              let%bind () = Unix.mkdir dir in
              dirs := dir :: !dirs;
              Deferred.List.iter streams ~how:`Sequential ~f:(fun stream ->
                let link_name = dir ^/ stream in
                let%map () = Unix.symlink ~target:(raw ^/ venue ^/ stream) ~link_name in
                links := link_name :: !links))
        in
        f view)
;;

let run ?venues ?(skip = []) ~data_dir ~out_dir date =
  let normalizers =
    match venues with
    | None -> normalizers
    | Some venues ->
      List.filter normalizers ~f:(fun n ->
        List.mem venues (Market_data.Normalizer.venue n) ~equal:Venue.equal)
  in
  with_view ~data_dir ~skip (fun data_dir ->
    Market_data.Rebuild_norm.run ~normalizers ~data_dir ~out_dir date)
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
     and skip =
       flag
         "-skip"
         (listed Skip.arg_type)
         ~doc:"VENUE:STREAM leave this raw stream out, e.g. binance:l2 (repeatable)"
     in
     fun () ->
       let venues = if List.is_empty venues then None else Some venues in
       let%map.Deferred.Or_error stats = run ?venues ~skip ~data_dir ~out_dir date in
       Core.print_s [%sexp (stats : Market_data.Rebuild_norm.Stats.t)])
;;
