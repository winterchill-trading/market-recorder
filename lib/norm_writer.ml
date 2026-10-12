open! Core
open! Async
module Event_log = Market_data.Event_log

type t = Event_log.Writer.t

let create
  ?(flush_interval = Time_ns.Span.of_int_ms 250)
  ?(snapshot_interval = Time_ns.Span.of_min 1.)
  ~data_dir
  ()
  =
  let snapshot_interval =
    if Time_ns.Span.( > ) snapshot_interval Time_ns.Span.zero
    then Some snapshot_interval
    else None
  in
  Event_log.Writer.create ~flush_interval ?snapshot_interval ~dir:data_dir ()
;;

let append = Event_log.Writer.append

let consume t ((module F) : Market_data.Feed.t) ~on_event =
  let drain pipe ~f =
    Pipe.iter_without_pushback pipe ~f:(fun x ->
      let event = f x in
      append t event;
      on_event event)
  in
  Deferred.all_unit
    [ drain F.trades ~f:(fun x -> Market_data.Event.Trade x)
    ; drain F.bbo ~f:(fun x -> Market_data.Event.Bbo x)
    ; drain F.l2 ~f:(fun x -> Market_data.Event.L2 x)
    ; drain F.funding ~f:(fun x -> Market_data.Event.Funding x)
    ]
;;

let flush = Event_log.Writer.flush
let close = Event_log.Writer.close
let files = Event_log.Writer.files
let snapshot_files = Event_log.Writer.snapshot_files
