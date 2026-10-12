open! Core

module Sample = struct
  type t =
    { name : string
    ; labels : (string * string) list
    ; value : string
    }
  [@@deriving sexp_of]
end

(* [k="v",k2="v2"}] up to and including the closing brace; returns the rest *)
let parse_labels s =
  let n = String.length s in
  let buf = Buffer.create 16 in
  let rec labels i acc =
    if i < n && Char.equal s.[i] '}'
    then Ok (List.rev acc, String.drop_prefix s (i + 1))
    else (
      match String.index_from s i '=' with
      | None -> Or_error.error_string "label without ="
      | Some eq ->
        let key = String.sub s ~pos:i ~len:(eq - i) in
        if eq + 1 >= n || not (Char.equal s.[eq + 1] '"')
        then Or_error.error_string "label value not quoted"
        else (
          Buffer.clear buf;
          let rec value j =
            if j >= n
            then Or_error.error_string "unterminated label value"
            else (
              match s.[j] with
              | '"' -> Ok (j + 1)
              | '\\' when j + 1 < n ->
                Buffer.add_char
                  buf
                  (match s.[j + 1] with
                   | 'n' -> '\n'
                   | c -> c);
                value (j + 2)
              | c ->
                Buffer.add_char buf c;
                value (j + 1))
          in
          Or_error.bind
            (value (eq + 2))
            ~f:(fun j ->
              let acc = (key, Buffer.contents buf) :: acc in
              if j < n && Char.equal s.[j] ',' then labels (j + 1) acc else labels j acc)))
  in
  labels 0 []
;;

let parse_line line =
  let open Or_error.Let_syntax in
  let name_end =
    String.lfindi line ~f:(fun _ c -> Char.equal c '{' || Char.is_whitespace c)
    |> Option.value ~default:(String.length line)
  in
  let name = String.prefix line name_end in
  let rest = String.drop_prefix line name_end in
  let%bind labels, rest =
    if String.is_prefix rest ~prefix:"{"
    then parse_labels (String.drop_prefix rest 1)
    else Ok ([], rest)
  in
  match String.split (String.strip rest) ~on:' ' with
  | value :: _ when not (String.is_empty name || String.is_empty value) ->
    Ok { Sample.name; labels; value }
  | _ -> Or_error.error_string "missing name or value"
;;

let parse text =
  String.split_lines text
  |> List.filter ~f:(fun l ->
    let l = String.strip l in
    not (String.is_empty l || String.is_prefix l ~prefix:"#"))
  |> List.map ~f:(fun line -> Or_error.tag (parse_line line) ~tag:line)
  |> Or_error.combine_errors
;;

let short name =
  let name = String.chop_prefix_if_exists name ~prefix:"market_recorder_" in
  String.chop_suffix_if_exists name ~suffix:"_total"
;;

let stream_labels = [ "venue"; "stream"; "symbol" ]

let stream_key (s : Sample.t) =
  List.map stream_labels ~f:(List.Assoc.find s.labels ~equal:String.equal) |> Option.all
;;

let table rows =
  let widths =
    List.fold rows ~init:[] ~f:(fun widths row ->
      List.mapi row ~f:(fun i cell ->
        Int.max (String.length cell) (Option.value (List.nth widths i) ~default:0)))
  in
  List.map rows ~f:(fun row ->
    List.mapi row ~f:(fun i cell ->
      let w = List.nth_exn widths i in
      (* text left, numbers right *)
      if i < List.length stream_labels
      then cell ^ String.make (w - String.length cell) ' '
      else String.make (w - String.length cell) ' ' ^ cell)
    |> String.concat ~sep:"  "
    |> String.rstrip)
  |> String.concat ~sep:"\n"
;;

let render samples =
  let per_stream, other =
    List.partition_map samples ~f:(fun s ->
      match stream_key s with
      | Some key -> First (key, s)
      | None -> Second s)
  in
  (* in order of first appearance *)
  let columns =
    List.fold per_stream ~init:[] ~f:(fun acc (_, s) ->
      if List.mem acc s.name ~equal:String.equal then acc else s.name :: acc)
    |> List.rev
  in
  let keys =
    List.map per_stream ~f:fst |> List.dedup_and_sort ~compare:[%compare: string list]
  in
  let cell key column =
    List.find_map per_stream ~f:(fun (k, s) ->
      if [%equal: string list] k key && String.equal s.name column
      then Some s.value
      else None)
    |> Option.value ~default:"-"
  in
  let header = stream_labels @ List.map columns ~f:short in
  let rows = List.map keys ~f:(fun key -> key @ List.map columns ~f:(cell key)) in
  let streams = if List.is_empty keys then [] else [ table (header :: rows) ] in
  let others =
    List.map other ~f:(fun s ->
      let labels =
        if List.is_empty s.labels
        then ""
        else
          sprintf
            "{%s}"
            (String.concat
               ~sep:","
               (List.map s.labels ~f:(fun (k, v) -> sprintf "%s=%s" k v)))
      in
      short s.name ^ labels, s.value)
  in
  let others =
    if List.is_empty others
    then []
    else (
      let w = List.fold others ~init:0 ~f:(fun w (k, _) -> Int.max w (String.length k)) in
      [ List.map others ~f:(fun (k, v) ->
          k ^ String.make (w - String.length k + 2) ' ' ^ v)
        |> String.concat ~sep:"\n"
      ])
  in
  String.concat ~sep:"\n\n" (streams @ others) ^ "\n"
;;
