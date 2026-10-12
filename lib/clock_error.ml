open! Core
open! Async

let parse_tracking line =
  match String.split (String.strip line) ~on:',' with
  | _ :: _ :: _ :: _ :: offset :: _ :: _ :: _ :: _ :: _ :: delay :: dispersion :: _ ->
    Or_error.try_with (fun () ->
      let f = Float.of_string in
      Float.abs (f offset) +. (f delay /. 2.) +. f dispersion |> Time_ns.Span.of_sec)
    |> Or_error.tag_s ~tag:[%message "chronyc tracking" line]
  | _ -> Or_error.error_s [%message "chronyc tracking: expected 14 fields" line]
;;

type t =
  { mutable latest : Time_ns.Span.t option
  ; ready : unit Ivar.t
  ; stopped : unit Ivar.t
  }

let sample (prog, args) =
  match%map Process.run ~prog ~args () with
  | Error e -> Error e
  | Ok out -> parse_tracking out
;;

let start
  ?(command = "chronyc", [ "-c"; "tracking" ])
  ?(interval = Time_ns.Span.of_sec 30.)
  ()
  =
  let t = { latest = None; ready = Ivar.create (); stopped = Ivar.create () } in
  don't_wait_for
    (match%map sample command with
     | Error e ->
       Log.Global.info_s
         [%message "no clock error gauge: chronyc tracking failed" (e : Error.t)];
       Ivar.fill_if_empty t.ready ()
     | Ok bound ->
       t.latest <- Some bound;
       Ivar.fill_if_empty t.ready ();
       Clock_ns.every'
         ~stop:(Ivar.read t.stopped)
         ~continue_on_error:false
         interval
         (fun () ->
            let%map result = sample command in
            t.latest <- Result.ok result));
  t
;;

let latest t = t.latest
let ready t = Ivar.read t.ready
let stop t = Ivar.fill_if_empty t.stopped ()

let register t metrics =
  Metrics.add_scalar
    metrics
    ~name:"market_recorder_clock_error_seconds"
    ~type_:"gauge"
    ~help:
      "Clock error bound from chronyc tracking: |offset| + root delay / 2 + root \
       dispersion."
    (fun () -> Option.map t.latest ~f:Time_ns.Span.to_sec)
;;
