(* NB: This needs to be pure OCaml (no Core!), since we need this in order to build
   Core. *)

(* This module generates lookup tables to detect integer overflow when calculating integer
   exponents.  At index [e], [table.[e]^e] will not overflow, but [(table[e] + 1)^e]
   will. *)

module Big_int = struct
  include Big_int
  type t = big_int
  let (>)  = gt_big_int
  let (<=) = le_big_int
  let (^)  = power_big_int_positive_int
  let (-)  = sub_big_int
  let (+)  = add_big_int
  let one  = unit_big_int
  let sqrt = sqrt_big_int
  let to_string = string_of_big_int
end

module Array = StdLabels.Array

type generated_type =
  | Int31
  | Int32
  | Int63
  | Int64

type type_info =
  { format_entry : Big_int.t -> string;
    max_val : Big_int.t;
    ocaml_type : string;
    generate_negative_bounds : bool;
    (* [maybe_32bit=true] means that we should check at
       runtime the size of integers (num_bits) - it might
       be 32bit (i.e., JavaScript) instead of 63bit or 31bit.
       This only applies to Int31 and Int63.
    *)
    maybe_32bit : bool
  }

let max_big_int_for_bits bits =
  let shift = bits - 1 in (* sign bit *)
  Big_int.((shift_left_big_int one shift) - one)
;;

let type_info_of_type =
  let type_info_for_ocaml_int max_val =
    let safe_to_print =
      let int31_max = max_big_int_for_bits 31 in
      fun x -> Big_int.(x <= int31_max)
    in
    let format_entry b =
       if safe_to_print b
       then Big_int.to_string b
       else Printf.sprintf "Int64.to_int %sL" (Big_int.to_string b)
    in
    { format_entry;
      max_val;
      ocaml_type = "int";
      generate_negative_bounds = false;
      maybe_32bit = true
    }
  in
  function
  | Int31 ->
    type_info_for_ocaml_int (max_big_int_for_bits 31)
  | Int63 ->
    type_info_for_ocaml_int (max_big_int_for_bits 63)
  | Int32 ->
    { format_entry = (fun b -> Big_int.to_string b ^ "l");
      max_val = max_big_int_for_bits 32;
      ocaml_type = "int32";
      generate_negative_bounds = false;
      maybe_32bit = false;
    }
  | Int64 ->
    { format_entry = (fun b -> Big_int.to_string b  ^ "L");
      max_val = max_big_int_for_bits 64;
      ocaml_type = "int64";
      generate_negative_bounds = true;
      maybe_32bit = false;
    }
;;

let highest_base exponent max_val =
  let open Big_int in
  match exponent with
  | 0 | 1 -> max_val
  | 2 -> sqrt max_val
  | _ ->
    let rec search possible_base =
      if possible_base ^ exponent > max_val then
        begin
          let res = possible_base - one in
          assert (res ^ exponent <= max_val);
          res
        end
      else
        search (possible_base + one)
    in
    search one
;;

let info32 = type_info_of_type Int32

let maybe_32bit info convert make_name =
  if info.maybe_32bit
  then Printf.sprintf "\n  if Int_conversions.num_bits_int = 32 then\n    %s %s\n  else\n    " convert (make_name info32)
  else "\n  "

let print_array ~info ~descr arr =
  let name info = Printf.sprintf "%s_%s_overflow_bounds" info.ocaml_type descr in
  Printf.printf
    "let %s : %s array =%s[|\n"
    (name info) info.ocaml_type (maybe_32bit info "Array.map Int32.to_int" name);
  let spaces = if info.maybe_32bit then String.make 6 ' ' else String.make 4 ' ' in
  Array.iter arr ~f:(fun b -> Printf.printf "%s%s;\n" spaces (info.format_entry b));
  Printf.printf "  |]\n\n";
;;

let gen_bounds ocaml_type =
  let info = type_info_of_type ocaml_type in
  let name info = Printf.sprintf "overflow_bound_max_%s_value" info.ocaml_type in
  Printf.printf
    "let %s : %s =%s%s\n\n"
    (name info)
    info.ocaml_type
    (maybe_32bit info "Int32.to_int" name)
    (info.format_entry info.max_val);

  let pos_bounds = Array.init 64 ~f:(fun i -> highest_base i info.max_val) in
  print_array ~info ~descr:"positive" pos_bounds;
  if info.generate_negative_bounds then
    begin
      let neg_bounds = Array.map pos_bounds ~f:Big_int.minus_big_int in
      print_array ~info ~descr:"negative" neg_bounds;
    end;
;;

let () =
  Printf.printf "(* This file was autogenerated by %s *)\n\n" Sys.argv.(0);
  Printf.printf "(* We have to use Int64.to_int_exn instead of int constants to make\n";
  Printf.printf "   sure that file can be preprocessed on 32-bit machines. *)\n\n";
  Printf.printf "#import \"config.mlh\"\n\n";
  gen_bounds Int32;
  Printf.printf "#if JSC_ARCH_SIXTYFOUR\n\n";
  gen_bounds Int63;
  Printf.printf "#else\n\n";
  gen_bounds Int31;
  Printf.printf "#endif\n\n";
  gen_bounds Int64;
;;
