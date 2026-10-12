open! Core
open! Async
open Market_recorder

let load_config path =
  match Config.load path with
  | Ok config -> config
  | Error e -> Error.raise e
;;

let run =
  Command.async
    ~summary:"Record the configured venues until SIGTERM or SIGINT"
    (let%map_open.Command config =
       flag "-config" (required string) ~doc:"FILE recorder configuration (sexp)"
     in
     fun () ->
       Log.Global.set_output [ Log.Output.stderr () ];
       let config = load_config config in
       let%bind recorder = Recorder.start config in
       let%bind server =
         Http_server.start ~port:config.http_port (Recorder.metrics recorder)
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

let () =
  Command.group
    ~summary:"Raw-first market data recorder"
    [ "run", run; "check-config", check ]
  |> Command_unix.run
;;
