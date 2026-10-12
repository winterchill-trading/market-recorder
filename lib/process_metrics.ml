open! Core

let version () =
  match Build_info.V1.version () with
  | Some v -> Build_info.V1.Version.to_string v
  | None -> "unknown"
;;

let count_dir dir =
  match Sys_unix.readdir dir with
  | names -> Some (Array.length names)
  | exception _ -> None
;;

(* Linux lists descriptors in /proc/self/fd, macOS in /dev/fd; both include the one opened
   to read the directory itself. *)
let open_fds () =
  match count_dir "/proc/self/fd" with
  | Some n -> Some (n - 1)
  | None -> Option.map (count_dir "/dev/fd") ~f:(fun n -> n - 1)
;;

let page_size = lazy (Int64.to_int_exn (Core_unix.sysconf_exn PAGESIZE))

(* the second field of /proc/self/statm is resident pages; Linux only *)
let rss_bytes () =
  match In_channel.read_all "/proc/self/statm" with
  | exception _ -> None
  | statm ->
    (match String.split (String.strip statm) ~on:' ' with
     | _ :: resident :: _ ->
       Option.map (Int.of_string_opt resident) ~f:(fun p -> p * force page_size)
     | _ -> None)
;;

let gauge buf name ~help ?(labels = "") value =
  bprintf buf "# HELP %s %s\n# TYPE %s gauge\n%s%s %s\n" name help name name labels value
;;

let render () =
  let buf = Buffer.create 512 in
  gauge
    buf
    "market_recorder_build_info"
    ~help:"Build version (git describe at build time) and compiler, always 1."
    ~labels:(sprintf {|{version="%s",ocaml="%s"}|} (version ()) Stdlib.Sys.ocaml_version)
    "1";
  Option.iter (open_fds ()) ~f:(fun n ->
    gauge buf "market_recorder_open_fds" ~help:"Open file descriptors." (Int.to_string n));
  Option.iter (rss_bytes ()) ~f:(fun n ->
    gauge
      buf
      "market_recorder_resident_memory_bytes"
      ~help:"Resident set size (Linux only)."
      (Int.to_string n));
  let gc = Gc.quick_stat () in
  let counter name ~help v =
    bprintf buf "# HELP %s %s\n# TYPE %s counter\n%s %d\n" name help name name v
  in
  counter
    "market_recorder_gc_minor_collections_total"
    ~help:"Minor GC collections."
    gc.minor_collections;
  counter
    "market_recorder_gc_major_collections_total"
    ~help:"Major GC cycles completed."
    gc.major_collections;
  counter "market_recorder_gc_compactions_total" ~help:"Heap compactions." gc.compactions;
  gauge
    buf
    "market_recorder_gc_heap_words"
    ~help:"Major heap size in words."
    (Int.to_string gc.heap_words);
  gauge
    buf
    "market_recorder_gc_top_heap_words"
    ~help:"Largest major heap size in words."
    (Int.to_string gc.top_heap_words);
  Buffer.contents buf
;;
