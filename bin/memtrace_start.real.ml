(* Starts memtrace when MEMTRACE names an output file; an empty or unset MEMTRACE does
   nothing. MEMTRACE_RATE sets the sampling rate. *)
let start () = Memtrace.trace_if_requested ~context:"market-recorder" ()
