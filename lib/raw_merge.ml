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

module Series = struct
  type t =
    { venue : Market_data.Venue.t
    ; stream : Market_data.Stream.t
    ; symbol_dir : string
    }
  [@@deriving sexp_of, compare]

  let of_file (f : Raw_minute.File.t) =
    { venue = f.venue; stream = f.stream; symbol_dir = f.symbol_dir }
  ;;
end

module Report = struct
  type t =
    { date : Date.t
    ; window : Time_ns.Span.t
    ; series : (Series.t * Counts.t) list
    ; total : Counts.t
    }
  [@@deriving sexp_of]

  let quote s =
    let b = Buffer.create (String.length s + 2) in
    Buffer.add_char b '"';
    String.iter s ~f:(fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | c when Char.to_int c < 0x20 ->
        Buffer.add_string b (sprintf "\\u%04x" (Char.to_int c))
      | c -> Buffer.add_char b c);
    Buffer.add_char b '"';
    Buffer.contents b
  ;;

  let counts_fields (c : Counts.t) =
    sprintf
      {|"minutes": %d, "only_a": %d, "only_b": %d, "both": %d, "gaps_closed": %d, "gaps_kept": %d|}
      c.minutes
      c.only_a
      c.only_b
      c.both
      c.gaps_closed
      c.gaps_kept
  ;;

  let to_json t =
    let series =
      List.map t.series ~f:(fun ((s : Series.t), c) ->
        sprintf
          {|    {"venue": %s, "stream": %s, "symbol": %s, %s}|}
          (quote (Market_data.Venue.to_string s.venue))
          (quote (Market_data.Stream.to_string s.stream))
          (quote s.symbol_dir)
          (counts_fields c))
    in
    sprintf
      "{\n\
      \  \"date\": %s,\n\
      \  \"window_ms\": %d,\n\
      \  \"total\": {%s},\n\
      \  \"series\": [\n\
       %s\n\
      \  ]\n\
       }\n"
      (quote (Date.to_string t.date))
      (Float.iround_nearest_exn (Time_ns.Span.to_ms t.window))
      (counts_fields t.total)
      (String.concat ~sep:",\n" series)
  ;;
end

let default_window = Time_ns.Span.of_sec 5.

let read_copy files =
  Deferred.Or_error.List.concat_map
    ~how:`Sequential
    files
    ~f:(fun (f : Raw_minute.File.t) ->
      Raw_minute.read f.path
      |> Deferred.Or_error.tag_s ~tag:[%message "reading raw minute file" ~path:f.path])
;;

let run ?(window = default_window) ~a_dir ~b_dir ~out_dir date =
  let%bind existing = Raw_minute.files ~data_dir:out_dir date in
  if not (List.is_empty existing)
  then
    Deferred.Or_error.error_s
      [%message
        "output already holds raw files of this day"
          (out_dir : string)
          ~first:(List.hd_exn existing).path]
  else (
    let%bind a_files = Raw_minute.files ~data_dir:a_dir date
    and b_files = Raw_minute.files ~data_dir:b_dir date in
    let key (_, (f : Raw_minute.File.t)) = Series.of_file f, f.minute in
    let tagged =
      List.map a_files ~f:(fun f -> A, f) @ List.map b_files ~f:(fun f -> B, f)
      |> List.stable_sort ~compare:(fun x y ->
        [%compare: Series.t * Time_ns.t] (key x) (key y))
    in
    let series =
      List.group tagged ~break:(fun x y ->
        Series.compare (fst (key x)) (fst (key y)) <> 0)
    in
    let errors = ref [] in
    let writer =
      Raw_writer.create
        ~now:(fun () -> Time_ns.max_value_representable)
        ~on_error:(fun ~venue:_ ~stream:_ ~symbol:_ e -> errors := e :: !errors)
        ~data_dir:out_dir
        ~on_closed:ignore
        ()
    in
    let%bind result =
      Deferred.Or_error.List.map ~how:`Sequential series ~f:(fun files ->
        let s = fst (key (List.hd_exn files)) in
        let minutes =
          List.group files ~break:(fun x y ->
            not (Time_ns.equal (snd (key x)) (snd (key y))))
        in
        let%map.Deferred.Or_error _carry, counts =
          Deferred.Or_error.List.fold
            minutes
            ~init:(Carry.empty, Counts.zero)
            ~f:(fun (carry, total) files ->
              let minute = snd (key (List.hd_exn files)) in
              let copy side =
                match
                  List.filter_map files ~f:(fun (s, f) ->
                    Option.some_if (equal_side s side) f)
                with
                | [] -> return (Ok None)
                | files -> read_copy files |> Deferred.Or_error.map ~f:Option.some
              in
              let%bind.Deferred.Or_error a = copy A in
              let%bind.Deferred.Or_error b = copy B in
              let lines, counts, carry = merge_minute ~window ~minute carry ~a ~b in
              List.iter lines ~f:(fun (line : Line.t) ->
                match line with
                | Frame { recv_ts; payload } ->
                  Raw_writer.write
                    writer
                    ~venue:s.venue
                    ~stream:s.stream
                    ~symbol:s.symbol_dir
                    ~recv_ts
                    payload
                | Disconnect ->
                  Raw_writer.disconnect
                    writer
                    ~venue:s.venue
                    ~stream:s.stream
                    ~symbol:s.symbol_dir
                    ~recv_ts:minute);
              let%map () = Raw_writer.roll writer in
              Ok (carry, Counts.(total + counts)))
        in
        s, counts)
    in
    let%bind () = Raw_writer.close writer in
    match result, !errors with
    | Error e, _ -> return (Error e)
    | Ok _, (_ :: _ as errors) ->
      Deferred.Or_error.error_s
        [%message "writing merged raw files failed" (errors : Error.t list)]
    | Ok series, [] ->
      let report =
        { Report.date
        ; window
        ; series
        ; total =
            List.fold series ~init:Counts.zero ~f:(fun acc (_, c) -> Counts.(acc + c))
        }
      in
      let dir = out_dir ^/ "_merge" in
      let%bind () = Unix.mkdir ~p:() dir in
      let%map () =
        Writer.save
          (dir ^/ Date.to_string date ^ ".json")
          ~contents:(Report.to_json report)
      in
      Ok report)
;;

let command =
  Command.async_or_error
    ~summary:"Merge two collectors' raw minute files of a day into one canonical copy"
    ~readme:(fun () ->
      "Reads <a>/raw and <b>/raw for the UTC day and writes <out>/raw in the same \
       layout: each frame once (matched by its text within -window, earliest recv_ts \
       kept), and a disconnect line only where both copies had a gap. Writes a \
       per-series report to <out>/_merge/<date>.json and prints the totals.")
    (let%map_open.Command a_dir =
       flag
         "-a"
         (required string)
         ~doc:"DIR first collector's data directory (holds raw/)"
     and b_dir = flag "-b" (required string) ~doc:"DIR second collector's data directory"
     and out_dir =
       flag "-out" (required string) ~doc:"DIR where to write the merged raw/ and _merge/"
     and date = flag "-date" (required date) ~doc:"YYYY-MM-DD UTC day to merge"
     and window =
       flag
         "-window"
         (optional_with_default default_window Time_ns.Span.arg_type)
         ~doc:"SPAN largest recv_ts difference of one frame's two copies (default 5s)"
     in
     fun () ->
       let%map.Deferred.Or_error report = run ~window ~a_dir ~b_dir ~out_dir date in
       Core.print_s [%sexp (report.total : Counts.t)])
;;
