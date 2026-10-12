open! Core
open! Async

module Stream_state = struct
  type t =
    { mutable last_logged : Time_ns.t
    ; mutable suppressed : int
    }
end

type t =
  { interval : Time_ns.Span.t
  ; now : unit -> Time_ns.t
  ; log : Sexp.t -> unit
  ; streams : Stream_state.t Hashtbl.M(Metrics.Key).t
  }

let create
  ?(interval = Time_ns.Span.of_min 1.)
  ?(now = Time_ns.now)
  ?(log = fun s -> Log.Global.error_s s)
  ()
  =
  { interval; now; log; streams = Hashtbl.create (module Metrics.Key) }
;;

let emit t (key : Metrics.Key.t) message ~suppressed =
  let stream =
    [%sexp
      { venue : Market_data.Venue.t = key.venue
      ; stream : Market_data.Stream.t = key.stream
      ; symbol : string = key.symbol
      }]
  in
  t.log
    (if suppressed = 0
     then [%message "" ~_:(message : Sexp.t) (stream : Sexp.t)]
     else [%message "" ~_:(message : Sexp.t) (stream : Sexp.t) (suppressed : int)])
;;

let warn t key message =
  let now = t.now () in
  match Hashtbl.find t.streams key with
  | None ->
    Hashtbl.set t.streams ~key ~data:{ last_logged = now; suppressed = 0 };
    emit t key message ~suppressed:0
  | Some s ->
    if Time_ns.Span.( < ) (Time_ns.diff now s.last_logged) t.interval
    then s.suppressed <- s.suppressed + 1
    else (
      emit t key message ~suppressed:s.suppressed;
      s.last_logged <- now;
      s.suppressed <- 0)
;;

let suppressed t =
  Hashtbl.fold t.streams ~init:0 ~f:(fun ~key:_ ~data:s n -> n + s.suppressed)
;;
