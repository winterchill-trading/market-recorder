open! Core
open! Async

let temp_dir () = Core_unix.mkdtemp (Filename.temp_dir_name ^/ "market-recorder-test")

let tree dir =
  let rec go rel =
    let abs = if String.is_empty rel then dir else dir ^/ rel in
    match%bind Sys.is_directory abs with
    | `Yes ->
      let%bind names = Sys.readdir abs in
      Deferred.List.concat_map ~how:`Sequential (Array.to_list names) ~f:(fun n ->
        go (if String.is_empty rel then n else rel ^/ n))
    | `No | `Unknown -> return [ rel ]
  in
  let%map files = go "" in
  List.sort files ~compare:String.compare
;;

let print_tree dir =
  let%map files = tree dir in
  List.iter files ~f:print_endline
;;

let unzstd path =
  let%map data = Reader.file_contents path in
  Zstd.decompress (Zstd.get_decompressed_size data) data
;;

let time s = Time_ns.of_string_with_utc_offset s
