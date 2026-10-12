open! Core

module Gap = struct
  type t =
    { first_missing : int
    ; last_missing : int
    ; at : Time_ns.t
    }
  [@@deriving sexp_of, equal]
end

module Pending = struct
  type t =
    { prev : int
    ; last : int
    ; recv_ts : Time_ns.t
    }

  let compare x y = [%compare: int * Time_ns.t] (x.last, x.recv_ts) (y.last, y.recv_ts)
end

type t =
  { reorder : Time_ns.Span.t
  ; pending : Pending.t Pairing_heap.t
  ; mutable newest : Time_ns.t
  ; mutable last : int option
  ; mutable gaps : Gap.t list (** newest first *)
  }

let create ?(reorder = Time_ns.Span.of_sec 1.) () =
  { reorder
  ; pending = Pairing_heap.create ~cmp:Pending.compare ()
  ; newest = Time_ns.epoch
  ; last = None
  ; gaps = []
  }
;;

let apply t ({ prev; last; recv_ts } : Pending.t) =
  match t.last with
  | None -> t.last <- Some last
  | Some seen ->
    if prev > seen
    then
      t.gaps <- { first_missing = seen + 1; last_missing = prev; at = recv_ts } :: t.gaps;
    if last > seen then t.last <- Some last
;;

let flush t =
  let rec go () =
    match Pairing_heap.pop t.pending with
    | None -> ()
    | Some p ->
      apply t p;
      go ()
  in
  go ()
;;

let add t ~recv_ts (check : Venue_seq.check) =
  t.newest <- Time_ns.max t.newest recv_ts;
  match check with
  | Restart at ->
    flush t;
    t.last <- Some at
  | Chain { prev; last } ->
    Pairing_heap.add t.pending { prev; last; recv_ts };
    let horizon = Time_ns.sub t.newest t.reorder in
    let rec go () =
      match Pairing_heap.top t.pending with
      | Some p when Time_ns.( <= ) p.recv_ts horizon ->
        ignore (Pairing_heap.pop_exn t.pending : Pending.t);
        apply t p;
        go ()
      | _ -> ()
    in
    go ()
;;

let gaps t = List.rev t.gaps
let clear_gaps t = t.gaps <- []
