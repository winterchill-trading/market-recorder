open! Core

module Gap = struct
  type t =
    { from : Time_ns.Alternate_sexp.t
    ; until : Time_ns.Alternate_sexp.t
    }
  [@@deriving sexp_of, equal]
end

type t =
  { threshold : Time_ns.Span.t
  ; buckets : int array (** intervals by [floor (log2 (us + 1))] *)
  ; mutable intervals : int
  ; mutable last : Time_ns.t
  ; mutable frames : int
  ; mutable silences : Gap.t list (** newest first *)
  }

let create ~threshold ~start () =
  { threshold
  ; buckets = Array.create ~len:64 0
  ; intervals = 0
  ; last = start
  ; frames = 0
  ; silences = []
  }
;;

let silence t until =
  if Time_ns.Span.( > ) (Time_ns.diff until t.last) t.threshold
  then t.silences <- { Gap.from = t.last; until } :: t.silences
;;

let add t time =
  silence t time;
  if t.frames > 0
  then (
    let us = Int.max 0 (Time_ns.Span.to_int_us (Time_ns.diff time t.last)) in
    let bucket = Int.floor_log2 (us + 1) in
    t.buckets.(bucket) <- t.buckets.(bucket) + 1;
    t.intervals <- t.intervals + 1);
  t.frames <- t.frames + 1;
  t.last <- Time_ns.max t.last time
;;

let finish t ~stop = silence t stop

let median_interval t =
  if t.intervals = 0
  then None
  else (
    let half = (t.intervals + 1) / 2 in
    let rec go i seen =
      let seen = seen + t.buckets.(i) in
      if seen >= half || i = 63 then i else go (i + 1) seen
    in
    let bucket = go 0 0 in
    Some (Time_ns.Span.of_int_us ((1 lsl (bucket + 1)) - 1)))
;;

let ticks t =
  match median_interval t with
  | None -> false
  | Some median -> Time_ns.Span.( <= ) median (Time_ns.Span.scale t.threshold 0.1)
;;

let suspected t = if ticks t then List.rev t.silences else []

let restart t =
  Array.fill t.buckets ~pos:0 ~len:64 0;
  t.intervals <- 0;
  t.silences <- []
;;
