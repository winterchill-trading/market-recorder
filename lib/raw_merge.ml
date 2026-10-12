open! Core
open! Async
module Raw_minute = Market_data.Raw_minute
module Line = Raw_minute.Line

module Counts = struct
  type t =
    { minutes : int
    ; only_a : int
    ; only_b : int
    ; both : int
    ; gaps_closed : int
    ; gaps_kept : int
    }
  [@@deriving sexp_of, equal]

  let zero =
    { minutes = 0; only_a = 0; only_b = 0; both = 0; gaps_closed = 0; gaps_kept = 0 }
  ;;

  let ( + ) x y =
    { minutes = x.minutes + y.minutes
    ; only_a = x.only_a + y.only_a
    ; only_b = x.only_b + y.only_b
    ; both = x.both + y.both
    ; gaps_closed = x.gaps_closed + y.gaps_closed
    ; gaps_kept = x.gaps_kept + y.gaps_kept
    }
  ;;
end

type side =
  | A
  | B
[@@deriving compare, equal]

let other = function
  | A -> B
  | B -> A
;;

module Carry = struct
  type entry =
    { side : side
    ; ts : Time_ns.t
    ; mutable used : bool
    }

  type t =
    { minute : Time_ns.t (** the minute the entries came from *)
    ; entries : entry list String.Table.t (** by frame text, in time order *)
    }

  let empty = { minute = Time_ns.epoch; entries = String.Table.create () }
end

type frame =
  { side : side
  ; idx : int
  ; ts : Time_ns.t
  ; payload : string
  }

type gap =
  { gap_idx : int
  ; start : Time_ns.t
  ; stop : Time_ns.t
  }

(* Frames in file order and disconnect spans of one copy of a minute. *)
let parse ~side ~minute ~stop lines =
  let frames = ref [] in
  let gaps = ref [] in
  let open_gaps = ref [] in
  let prev = ref minute in
  List.iteri lines ~f:(fun idx (line : Line.t) ->
    match line with
    | Frame { recv_ts; payload } ->
      List.iter !open_gaps ~f:(fun (gap_idx, start) ->
        gaps := { gap_idx; start; stop = Time_ns.max start recv_ts } :: !gaps);
      open_gaps := [];
      frames := { side; idx; ts = recv_ts; payload } :: !frames;
      prev := Time_ns.max !prev recv_ts
    | Disconnect -> open_gaps := (idx, !prev) :: !open_gaps);
  List.iter !open_gaps ~f:(fun (gap_idx, start) ->
    gaps := { gap_idx; start; stop } :: !gaps);
  List.rev !frames, List.rev !gaps
;;

let overlaps (s1, e1) (s2, e2) = Time_ns.(max s1 s2 <= min e1 e2)

let merge_minute ~window ~minute (carry : Carry.t) ~a ~b =
  let stop = Time_ns.add minute Time_ns.Span.minute in
  let a_frames, a_gaps = parse ~side:A ~minute ~stop (Option.value a ~default:[]) in
  let b_frames, b_gaps = parse ~side:B ~minute ~stop (Option.value b ~default:[]) in
  let spans gaps = List.map gaps ~f:(fun g -> g.start, g.stop) in
  (* a copy without a file for the minute is a gap over the whole minute *)
  let peer_spans copy gaps =
    match copy with
    | None -> [ minute, stop ]
    | Some _ -> spans gaps
  in
  let a_spans = peer_spans a a_gaps
  and b_spans = peer_spans b b_gaps in
  let carried =
    if Time_ns.equal carry.minute (Time_ns.sub minute Time_ns.Span.minute)
    then carry.entries
    else String.Table.create ()
  in
  let next_carry = String.Table.create () in
  let only_a = ref 0
  and only_b = ref 0
  and both = ref 0 in
  let bump side by =
    match side with
    | A -> only_a := !only_a + by
    | B -> only_b := !only_b + by
  in
  let emitted = ref [] in
  let emit (f : frame) =
    emitted
    := (f.ts, 0, f.side, f.idx, Line.Frame { recv_ts = f.ts; payload = f.payload })
       :: !emitted
  in
  let unmatched (f : frame) =
    let match_carried =
      match Hashtbl.find carried f.payload with
      | None -> None
      | Some entries ->
        List.find entries ~f:(fun (e : Carry.entry) ->
          (not e.used)
          && equal_side e.side (other f.side)
          && Time_ns.Span.( <= ) (Time_ns.abs_diff f.ts e.ts) window)
    in
    match match_carried with
    | Some e ->
      e.used <- true;
      incr both;
      bump e.side (-1)
    | None ->
      bump f.side 1;
      emit f;
      if Time_ns.( >= ) f.ts (Time_ns.sub stop window)
      then
        Hashtbl.add_multi
          next_carry
          ~key:f.payload
          ~data:{ Carry.side = f.side; ts = f.ts; used = false }
  in
  let by_text = String.Table.create () in
  List.iter a_frames ~f:(fun f -> Hashtbl.add_multi by_text ~key:f.payload ~data:f);
  List.iter b_frames ~f:(fun f -> Hashtbl.add_multi by_text ~key:f.payload ~data:f);
  Hashtbl.iter by_text ~f:(fun frames ->
    (* add_multi prepends: restore file order, then split by copy *)
    let frames = List.rev frames in
    let sort =
      List.stable_sort ~compare:(fun (x : frame) y -> Time_ns.compare x.ts y.ts)
    in
    let xs = sort (List.filter frames ~f:(fun f -> equal_side f.side A))
    and ys = sort (List.filter frames ~f:(fun f -> equal_side f.side B)) in
    let rec go xs ys =
      match xs, ys with
      | [], rest | rest, [] -> List.iter rest ~f:unmatched
      | (x : frame) :: xs', (y : frame) :: ys' ->
        if Time_ns.Span.( <= ) (Time_ns.abs_diff x.ts y.ts) window
        then (
          incr both;
          emit (if Time_ns.( <= ) x.ts y.ts then x else y);
          go xs' ys')
        else if Time_ns.( < ) x.ts y.ts
        then (
          unmatched x;
          go xs' ys)
        else (
          unmatched y;
          go xs ys')
    in
    go xs ys);
  Hashtbl.map_inplace next_carry ~f:List.rev;
  let gaps_closed = ref 0
  and gaps_kept = ref 0 in
  let keep side (g : gap) =
    incr gaps_kept;
    emitted := (g.start, 1, side, g.gap_idx, Line.Disconnect) :: !emitted
  in
  let kept_a =
    List.filter a_gaps ~f:(fun g ->
      if List.exists b_spans ~f:(overlaps (g.start, g.stop))
      then (
        keep A g;
        true)
      else (
        incr gaps_closed;
        false))
  in
  List.iter b_gaps ~f:(fun g ->
    let span = g.start, g.stop in
    if List.exists a_spans ~f:(overlaps span)
       && not (List.exists (spans kept_a) ~f:(overlaps span))
    then keep B g
    else incr gaps_closed);
  let lines =
    List.sort !emitted ~compare:(fun (t1, r1, s1, i1, _) (t2, r2, s2, i2, _) ->
      [%compare: Time_ns.t * int * side * int] (t1, r1, s1, i1) (t2, r2, s2, i2))
    |> List.map ~f:(fun (_, _, _, _, line) -> line)
  in
  let counts =
    { Counts.minutes = (if List.is_empty lines then 0 else 1)
    ; only_a = !only_a
    ; only_b = !only_b
    ; both = !both
    ; gaps_closed = !gaps_closed
    ; gaps_kept = !gaps_kept
    }
  in
  lines, counts, { Carry.minute; entries = next_carry }
;;
