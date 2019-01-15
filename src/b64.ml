(*
 * Copyright (c) 2006-2009 Citrix Systems Inc.
 * Copyright (c) 2010 Thomas Gazagnaire <thomas@gazagnaire.com>
 * Copyright (c) 2014-2016 Anil Madhavapeddy <anil@recoil.org>
 * Copyright (c) 2016 David Kaloper Meršinjak
 * Copyright (c) 2018 Romain Calascibetta <romain.calascibetta@gmail.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

let () = Printexc.record_backtrace true

type alphabet =
  { emap : int array
  ; dmap : int array }

let (//) x y =
  if y < 1 then raise Division_by_zero ;
  if x > 0 then 1 + ((x - 1) / y) else 0
[@@inline]

external unsafe_get_uint8 : string -> int -> int = "%string_unsafe_get" [@@noalloc]
external unsafe_set_uint8 : bytes -> int -> int -> unit= "%bytes_unsafe_set" [@@noalloc]
external unsafe_set_uint16 : bytes -> int -> int -> unit = "%caml_string_set16u" [@@noalloc]
external swap16 : int -> int = "%bswap16" [@@noalloc]

let none = (-1)

exception Exists

let padding_exists alphabet =
  try String.iter (function '=' -> raise Exists | _ -> ()) alphabet; false
  with Exists -> true

let make_alphabet alphabet =
  if String.length alphabet <> 64 then invalid_arg "Length of alphabet must be 64" ;
  if padding_exists alphabet then invalid_arg "Alphabet can not contain padding character" ;
  let emap = Array.init (String.length alphabet) (unsafe_get_uint8 alphabet)  in
  let dmap = Array.make 255 none in
  String.iteri (fun idx chr -> Array.unsafe_set dmap (Char.code chr) idx) alphabet ;
  { emap; dmap; }

let length_alphabet { emap; _ } = Array.length emap

let default_alphabet = make_alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
let uri_safe_alphabet = make_alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

let unsafe_set_be_uint16 =
  if Sys.big_endian
  then fun t off v -> unsafe_set_uint16 t off v
  else fun t off v -> unsafe_set_uint16 t off (swap16 v)

exception Out_of_bound

let get_uint8 t off =
  if off < 0 || off >= String.length t then raise Out_of_bound ;
  unsafe_get_uint8 t off

let padding = int_of_char '='

let encode pad { emap; _ } input =
  let n = String.length input in
  let n' = n // 3 * 4 in
  let res = Bytes.create n' in

  let emap i = Array.unsafe_get emap i in

  let emit b1 b2 b3 i =
    unsafe_set_be_uint16 res i ((emap (b1 lsr 2 land 0x3f) lsl 8) lor (emap ((b1 lsl 4) lor (b2 lsr 4) land 0x3f))) ;
    unsafe_set_be_uint16 res (i + 2) ((emap ((b2 lsl 2) lor (b3 lsr 6) land 0x3f) lsl 8) lor (emap (b3 land 0x3f))) in

  let rec enc j i =
    if i = n then ()
    else if i = n - 1 then emit (unsafe_get_uint8 input i) 0 0 j
    else if i = n - 2 then emit (unsafe_get_uint8 input i) (unsafe_get_uint8 input (i + 1)) 0 j
    else
    (emit
       (unsafe_get_uint8 input i)
       (unsafe_get_uint8 input (i + 1))
       (unsafe_get_uint8 input (i + 2))
       j ;
     enc (j + 4) (i + 3)) in

  let rec fix = function
  | 0 -> ()
  | i -> unsafe_set_uint8 res (n' - i) padding ; fix (i - 1) in

  enc 0 0 ;

  if pad
  then begin fix ((3 - n mod 3) mod 3) ; Bytes.unsafe_to_string res end
  else Bytes.sub_string res 0 (n / 3 * 4)

let encode ?(pad = true) ?(alphabet = default_alphabet) input = encode pad alphabet input

let decode_result { dmap; _ } input =
  let n = String.length input in
  let n' = (n / 4) * 3 in
  let res = Bytes.create n' in

  let emit a b c d i =
    let x = (a lsl 18) lor (b lsl 12) lor (c lsl 6) lor d in
    unsafe_set_be_uint16 res i (x lsr 8) ;
    unsafe_set_uint8 res (i + 2) (x land 0xff) in

  let dmap i =
    let x = Array.unsafe_get dmap i in
    if x = none then raise Not_found else x in

  let rec dec j i =
    if i = n then Some 0
    else begin
      let a = dmap (get_uint8 input i) in
      let b = dmap (get_uint8 input (i + 1)) in
      let (d, pad) =
        let x = get_uint8 input (i + 3) in
        try (dmap x, 0) with Not_found when x = padding -> (0, 1) in
      let (c, pad) =
        let x = get_uint8 input (i + 2) in
        try (dmap x, pad) with Not_found when x = padding && pad = 1 -> (0, 2) in

      emit a b c d j ;
      if pad = 0
      then dec (j + 3) (i + 4)
      else if i + 4 <> n then None
      else Some pad end in

  match dec 0 0 with
  | Some pad -> Ok (Bytes.sub_string res 0 (n' - pad))
  | None -> Error `Wrong_padding
  | exception Out_of_bound ->
      (* appear when [get_uint8] wants to access to an invalid area *)
      Error `Wrong_padding
  | exception Not_found ->
      (* appear when [dmap] not found associated character.
         an other branch is when we got '=' (so [dmap] returns [Not_found]) and the last
         character is not an '='. *)
      Error `Malformed

let decode_result ?(alphabet = default_alphabet) input = decode_result alphabet input

let decode_opt ?alphabet input =
  match decode_result ?alphabet input with
  | Ok res -> Some res
  | Error _ -> None

let decode ?alphabet input =
  match decode_opt ?alphabet input with
  | Some res -> res
  | None -> invalid_arg "Invalid Base64 input"
