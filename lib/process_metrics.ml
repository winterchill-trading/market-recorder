open! Core

let version () =
  match Build_info.V1.version () with
  | Some v -> Build_info.V1.Version.to_string v
  | None -> "unknown"
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
  Buffer.contents buf
;;
