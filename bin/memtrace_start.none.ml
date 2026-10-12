(* Built without the memtrace library: MEMTRACE is ignored. *)
let start () =
  match Sys.getenv_opt "MEMTRACE" with
  | None | Some "" -> ()
  | Some _ -> prerr_endline "market-recorder: built without memtrace, MEMTRACE ignored"
;;
