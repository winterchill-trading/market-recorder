open! Core

module Endpoint = struct
  type t =
    | Mainnet
    | Testnet
    | Local of { port : int option [@sexp.option] }
    | Custom of
        { base_url : string
        ; ws_url : string option [@sexp.option]
        }
  [@@deriving sexp, compare, equal]

  let ws_url = Option.map ~f:Uri.of_string

  let hyperliquid = function
    | Mainnet -> Hl_client.Config.mainnet ()
    | Testnet -> Hl_client.Config.testnet ()
    | Local { port = None } -> Hl_client.Config.local ()
    | Local { port = Some port } ->
      Hl_client.Config.create
        ~base_url:(Uri.of_string (sprintf "http://localhost:%d" port))
        ()
    | Custom { base_url; ws_url = w } ->
      Hl_client.Config.create ?ws_url:(ws_url w) ~base_url:(Uri.of_string base_url) ()
  ;;

  (* Public market streams need no key; the simulator wants some account name. *)
  let binance = function
    | Mainnet -> Binance_client.Config.mainnet ~api_key:"" ~api_secret:"" ()
    | Testnet -> Binance_client.Config.testnet ~api_key:"" ~api_secret:"" ()
    | Local { port } -> Binance_client.Config.local ?port ~api_key:"market-recorder" ()
    | Custom { base_url; ws_url = w } ->
      Binance_client.Config.create
        ?ws_url:(ws_url w)
        ~base_url:(Uri.of_string base_url)
        ~api_key:""
        ()
  ;;

  let bybit = function
    | Mainnet -> Bybit_client.Config.mainnet ()
    | Testnet -> Bybit_client.Config.testnet ()
    | Local { port } -> Bybit_client.Config.local ?port ()
    | Custom { base_url; ws_url = w } ->
      Bybit_client.Config.create
        ?ws_public_url:(ws_url w)
        ~base_url:(Uri.of_string base_url)
        ()
  ;;
end

module Venue_entry = struct
  type t =
    { venue : Market_data.Venue.t
    ; symbols : string list
    ; streams : Market_data.Stream.t list
    ; config : Endpoint.t [@default Mainnet]
    }
  [@@deriving sexp, compare, equal]
end

module Upload = struct
  type t =
    { command : string list
    ; delete_after_upload : bool [@default false]
    }
  [@@deriving sexp, compare, equal]
end

type t =
  { data_dir : string
  ; http_port : int [@default 9100]
  ; venues : Venue_entry.t list
  ; upload : Upload.t option [@sexp.option]
  }
[@@deriving sexp, compare, equal]

let validate t =
  let errors =
    List.concat
      [ (if List.is_empty t.venues then [ "no venues" ] else [])
      ; List.concat_map t.venues ~f:(fun (v : Venue_entry.t) ->
          let name = Market_data.Venue.to_string v.venue in
          List.concat
            [ (if List.is_empty v.symbols then [ name ^ ": no symbols" ] else [])
            ; (if List.is_empty v.streams then [ name ^ ": no streams" ] else [])
            ; (if List.mem v.streams Private ~equal:Market_data.Stream.equal
               then [ name ^ ": Private streams cannot be recorded" ]
               else [])
            ])
      ; (match t.upload with
         | Some { command = []; _ } -> [ "upload: empty command" ]
         | _ -> [])
      ]
  in
  match errors with
  | [] -> Ok t
  | errors -> Or_error.error_s [%message "invalid config" (errors : string list)]
;;

let of_sexp sexp =
  Or_error.try_with (fun () -> t_of_sexp sexp) |> Or_error.bind ~f:validate
;;

let load path =
  Or_error.try_with (fun () -> Sexp.load_sexp path)
  |> Or_error.bind ~f:of_sexp
  |> Or_error.tag ~tag:path
;;
