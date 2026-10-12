open! Core
open! Async

type t =
  { count_above : Time_ns.Span.t
  ; warn_above : Time_ns.Span.t
  ; warn_every : Time_ns.Span.t
  ; now : unit -> Time_ns.t
  ; warn : Sexp.t -> unit
  ; mutable long_cycles : int
  ; mutable longest : Time_ns.Span.t
  ; mutable last_warning : Time_ns.t option
  ; mutable suppressed : int
  }

let create
  ?(count_above = Time_ns.Span.of_int_ms 50)
  ?(warn_above = Time_ns.Span.of_int_ms 20)
  ?(warn_every = Time_ns.Span.of_sec 10.)
  ?(now = Time_ns.now)
  ?(warn = fun s -> Log.Global.info_s s)
  ()
  =
  { count_above
  ; warn_above
  ; warn_every
  ; now
  ; warn
  ; long_cycles = 0
  ; longest = Time_ns.Span.zero
  ; last_warning = None
  ; suppressed = 0
  }
;;

let observe t cycle =
  if Time_ns.Span.( > ) cycle t.count_above then t.long_cycles <- t.long_cycles + 1;
  if Time_ns.Span.( > ) cycle t.warn_above
  then (
    t.longest <- Time_ns.Span.max t.longest cycle;
    let now = t.now () in
    match t.last_warning with
    | Some last when Time_ns.Span.( < ) (Time_ns.diff now last) t.warn_every ->
      t.suppressed <- t.suppressed + 1
    | _ ->
      t.warn
        [%message
          "long async cycle"
            (cycle : Time_ns.Span.t)
            ~suppressed_since_last_warning:(t.suppressed : int)];
      t.last_warning <- Some now;
      t.suppressed <- 0)
;;

let start t =
  Async_kernel.Stream.iter (Scheduler.long_cycles ~at_least:t.warn_above) ~f:(observe t)
;;

let long_cycles t = t.long_cycles
let longest t = t.longest

let register t metrics =
  Metrics.add_scalar
    metrics
    ~name:"market_recorder_long_cycles_total"
    ~type_:"counter"
    ~help:"Async scheduler cycles longer than 50ms."
    (fun () -> Some (Float.of_int t.long_cycles));
  Metrics.add_scalar
    metrics
    ~name:"market_recorder_longest_cycle_seconds"
    ~type_:"gauge"
    ~help:"The longest Async cycle over 20ms since start."
    (fun () -> Some (Time_ns.Span.to_sec t.longest))
;;
