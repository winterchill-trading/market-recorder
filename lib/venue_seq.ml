open! Core

type check =
  | Chain of
      { prev : int
      ; last : int
      }
  | Restart of int
[@@deriving sexp_of, equal]

type t =
  { identity : string option
  ; check : check option
  }
[@@deriving sexp_of, equal]

let none = { identity = None; check = None }

let has_sequence ~(venue : Market_data.Venue.t) ~(stream : Market_data.Stream.t) =
  match venue, stream with
  | Binance, (L2 | Trades) | Bybit, L2 -> true
  | _ -> false
;;

let field_int frame ~key =
  let pattern = sprintf "%S:" key in
  match String.substr_index frame ~pattern with
  | None -> None
  | Some i ->
    let n = String.length frame in
    let rec skip j = if j < n && Char.equal frame.[j] ' ' then skip (j + 1) else j in
    let start = skip (i + String.length pattern) in
    let start = if start < n && Char.equal frame.[start] '"' then start + 1 else start in
    let rec digits j = if j < n && Char.is_digit frame.[j] then digits (j + 1) else j in
    let stop = digits start in
    if stop = start
    then None
    else Int.of_string_opt (String.sub frame ~pos:start ~len:(stop - start))
;;

let contains frame pattern = String.is_substring frame ~substring:pattern

let of_frame ~(venue : Market_data.Venue.t) ~(stream : Market_data.Stream.t) frame =
  match venue, stream with
  | Binance, L2 when contains frame {|"depthUpdate"|} ->
    (match field_int frame ~key:"u", field_int frame ~key:"pu" with
     | Some u, Some pu ->
       { identity = Some (sprintf "u:%d" u)
       ; check = Some (Chain { prev = pu; last = u })
       }
     | _ -> none)
  | Binance, Trades when contains frame {|"aggTrade"|} ->
    (match field_int frame ~key:"a" with
     | Some a ->
       { identity = Some (sprintf "a:%d" a)
       ; check = Some (Chain { prev = a - 1; last = a })
       }
     | None -> none)
  | Bybit, L2 when contains frame {|"topic":"orderbook.|} ->
    (match field_int frame ~key:"u" with
     | None -> none
     | Some u ->
       if contains frame {|"type":"snapshot"|}
       then
         { identity = Some (sprintf "snapshot:%d" u)
         ; check = (if u = 1 then Some (Restart 1) else None)
         }
       else
         { identity = Some (sprintf "delta:%d" u)
         ; check = Some (Chain { prev = u - 1; last = u })
         })
  | _ -> none
;;
