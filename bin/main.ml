open! Core
open! Async
open Market_recorder

let load_config path =
  match Config.load path with
  | Ok config -> config
  | Error e ->
    (* a readable message, not an uncaught exception with a backtrace *)
    Core.eprint_s [%sexp (e : Error.t)];
    Stdlib.exit 1
;;

let run =
  Command.async
    ~summary:"Record the configured venues until SIGTERM or SIGINT"
    (let%map_open.Command config =
       flag "-config" (required string) ~doc:"FILE recorder configuration (sexp)"
     and collector =
       flag
         "-collector"
         (optional Raw_files.collector_arg)
         ~doc:
           "ID add this collector id to raw minute file names (<HH>-<MM>.<ID>.ndjson), \
            for two collectors of one venue"
     in
     fun () ->
       Log.Global.set_output [ Log.Output.stderr () ];
       let config = load_config config in
       let%bind recorder = Recorder.start ?collector config in
       let clock_error = Clock_error.start () in
       Clock_error.register clock_error (Recorder.metrics recorder);
       let%bind server =
         Http_server.start
           ~port:config.http_port
           ~status:(fun () -> [%sexp (Recorder.status recorder : Recorder.Status.t)])
           (Recorder.metrics recorder)
       in
       Log.Global.info_s
         [%message
           "listening"
             ~http_port:(Http_server.port server : int)
             ~data_dir:(config.data_dir : string)];
       let stopped = Ivar.create () in
       Signal.handle [ Signal.term; Signal.int ] ~f:(fun signal ->
         if Ivar.is_empty stopped
         then (
           Log.Global.info_s [%message "stopping" (signal : Signal.t)];
           Ivar.fill_if_empty stopped ()));
       let%bind () = Ivar.read stopped in
       Clock_error.stop clock_error;
       let%bind () = Recorder.stop recorder in
       let%bind () = Http_server.close server in
       Log.Global.info "stopped";
       Log.Global.flushed ())
;;

let check =
  Command.basic
    ~summary:"Parse and validate a configuration, then print it"
    (let%map_open.Command config =
       flag "-config" (required string) ~doc:"FILE recorder configuration (sexp)"
     in
     fun () -> Core.print_s [%sexp (load_config config : Config.t)])
;;

let status =
  Command.async
    ~summary:"Print a running recorder's /metrics as tables"
    (let%map_open.Command url =
       flag
         "-url"
         (optional_with_default "http://localhost:9100" string)
         ~doc:
           "URL base URL of the recorder's HTTP endpoint (default http://localhost:9100)"
     in
     fun () ->
       let uri =
         Uri.of_string (String.chop_suffix_if_exists url ~suffix:"/" ^ "/metrics")
       in
       let%bind response, body = Cohttp_async.Client.get uri in
       let%map body = Cohttp_async.Body.to_string body in
       match Cohttp.Response.status response with
       | `OK ->
         (match Status_table.parse body with
          | Ok samples -> Core.print_string (Status_table.render samples)
          | Error e ->
            Core.eprint_s [%sexp (e : Error.t)];
            Stdlib.exit 1)
       | status ->
         Core.eprint_s
           [%message
             "unexpected status"
               ~uri:(Uri.to_string uri)
               ~status:(Cohttp.Code.string_of_status status)];
         Stdlib.exit 1)
;;

let () =
  Command.group
    ~summary:"Raw-first market data recorder"
    [ "run", run
    ; "check-config", check
    ; "status", status
    ; "rebuild-norm", Rebuild.command
    ; "merge", Raw_merge.command
    ]
  |> Command_unix.run
;;
