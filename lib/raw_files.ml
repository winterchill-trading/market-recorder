open! Core
open! Async
module Raw_minute = Market_data.Raw_minute

let check_collector c =
  if (not (String.is_empty c))
     && String.length c <= 32
     && String.for_all c ~f:(fun ch -> Char.is_alphanum ch || Char.equal ch '_')
  then Ok ()
  else Or_error.error_s [%message "collector id must be 1 to 32 of [A-Za-z0-9_]" c]
;;

let collector_arg =
  Command.Arg_type.create (fun c ->
    ok_exn (check_collector c);
    c)
;;

let parse_name name =
  let stem, suffix =
    match String.chop_suffix name ~suffix:".ndjson.zst" with
    | Some stem -> Some stem, ".ndjson.zst"
    | None -> String.chop_suffix name ~suffix:".ndjson", ".ndjson"
  in
  Option.bind stem ~f:(fun stem ->
    let minute, collector =
      match String.lsplit2 stem ~on:'.' with
      | None -> stem, None
      | Some (minute, collector) -> minute, Some collector
    in
    let is_minute =
      String.length minute = 5
      && Char.equal minute.[2] '-'
      && String.for_alli minute ~f:(fun i c -> i = 2 || Char.is_digit c)
    in
    let collector_ok =
      Option.for_all collector ~f:(fun c -> Result.is_ok (check_collector c))
    in
    Option.some_if (is_minute && collector_ok) (collector, minute ^ suffix))
;;

let ls dir =
  match%bind Sys.is_directory_exn dir with
  | false -> return []
  | true ->
    let%map names = Sys.readdir dir in
    Array.to_list names |> List.sort ~compare:String.compare
;;

let files ?collector ~data_dir date =
  let raw = data_dir ^/ "raw" in
  let day_dir =
    sprintf
      "%04d/%02d/%02d"
      (Date.year date)
      (Month.to_int (Date.month date))
      (Date.day date)
  in
  let%bind venues = ls raw in
  let%map files =
    Deferred.List.concat_map venues ~how:`Sequential ~f:(fun venue ->
      let%bind streams = ls (raw ^/ venue) in
      Deferred.List.concat_map streams ~how:`Sequential ~f:(fun stream ->
        let%bind symbols = ls (raw ^/ venue ^/ stream) in
        Deferred.List.concat_map symbols ~how:`Sequential ~f:(fun symbol ->
          let dir = raw ^/ venue ^/ stream ^/ symbol ^/ day_dir in
          let%map names = ls dir in
          List.filter_map names ~f:(fun name ->
            match parse_name name with
            | Some (c, plain) when [%equal: string option] c collector ->
              Raw_minute.File.of_path (dir ^/ plain)
              |> Result.ok
              |> Option.map ~f:(fun (f : Raw_minute.File.t) ->
                { f with path = dir ^/ name })
            | _ -> None))))
  in
  List.sort files ~compare:(fun (a : Raw_minute.File.t) (b : Raw_minute.File.t) ->
    [%compare: Market_data.Venue.t * Market_data.Stream.t * string * Time_ns.t * bool]
      (a.venue, a.stream, a.symbol_dir, a.minute, not a.compressed)
      (b.venue, b.stream, b.symbol_dir, b.minute, not b.compressed))
;;
