(* *********************************************************i************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Xavier Leroy, INRIA Paris-Rocquencourt                     *)
(*           Prashanth Mundkur, SRI International                      *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(*  The contributions by Prashanth Mundkur are reused and adapted      *)
(*  under the terms of a Contributor License Agreement between         *)
(*  SRI International and INRIA.                                       *)
(*                                                                     *)
(* *********************************************************************)

(* Printing eBPF assembly code in asm syntax *)

open Printf
open Camlcoq
open Ctypes
open Sections
open Asm
open PrintAsmaux
open Fileinfo

(* Module containing the printing functions *)

module Target : TARGET =
  struct

    (* Basic printing functions *)

    let comment = "#"

    let symbol        = elf_symbol
    let label         = elf_label

    let rec print_label oc lbl = label oc (transl_label lbl)

    and print_label_or_ident oc = function
      | Datatypes.Coq_inl label -> print_label oc label
      | Datatypes.Coq_inr ident -> symbol oc ident

    let use_abi_name = false

    let int_reg_num_name = function _ -> "reg"

    let int_reg_abi_name = function _ -> "abi"

    let float_reg_num_name = function _ -> "float_reg"

    let float_reg_abi_name = function _ -> "float_abi"

    let int_reg_name   = if use_abi_name then int_reg_abi_name   else int_reg_num_name
    let float_reg_name = if use_abi_name then float_reg_abi_name else float_reg_num_name

    let _ = int_reg_name;;
    let _ = float_reg_name;;

    let sizeOp oc mem =
      let sizeOp_name = function
        | Byte -> "u8"
        | HalfWord -> "u16"
        | Word -> "u32"
        | SignedWord -> "u32"
      in output_string oc (sizeOp_name mem)

    let operator oc op =
      let operator_name = function
        | ADD -> " += " | SUB -> " -= " | MUL -> " *= " | DIV -> " /= "
        | OR -> " |= " | AND -> " &= " | LSH -> " <<= " | RSH -> " >>= "
        | NEG -> " -" | MOD -> " %= " | XOR -> " ^= " | MOV -> " = " | ARSH -> " s>>= "
      in output_string oc (operator_name op)

    let rec register oc ireg =
      let register_name = function
        | R0 -> "r0" | R1 -> "r1" | R2 -> "r2" | R3 -> "r3" | R4 -> "r4" | R5 -> "r5"
        | R6 -> "r6" | R7 -> "r7" | R8 -> "r8" | R9 -> "r9" | R10 -> "r10"
      in output_string oc (register_name ireg)

    and immediate = coqint

    and register_or_immediate oc = function
      | Datatypes.Coq_inl reg -> register oc reg
      | Datatypes.Coq_inr imm -> immediate oc imm

    let rec cmpOp = function
      | EQ -> "=="
      | NE -> "!="
      | SET -> "&="
      | GT Signed -> "s>"
      | GT Unsigned -> ">"
      | GE Signed -> "s>="
      | GE Unsigned -> ">="
      | LT Signed -> "s<"
      | LT Unsigned -> "<"
      | LE Signed -> "s<="
      | LE Unsigned -> "<="

    and print_cmp oc op reg regimm =
      fprintf oc "	%a = (%a %s %a)\n" register reg register reg (cmpOp op) register_or_immediate regimm

    and print_jump_cmp oc op reg regimm label =
      fprintf oc "	if %a %s %a goto %a\n" register reg (cmpOp op) register_or_immediate regimm print_label label

(* Names of sections *)

    let name_of_section = function
      | Section_text         -> ".text"
      | Section_data i | Section_small_data i ->
          variable_section ~sec:".data" ~bss:".bss" i
      | Section_const i | Section_small_const i ->
          variable_section ~sec:".section	.rodata" i
      | Section_string       -> ".section	.rodata"
      | Section_literal      -> ".section	.rodata"
      | Section_jumptable    -> ".section	.rodata"
      | Section_debug_info _ -> ".section	.debug_info,\"\",%progbits"
      | Section_debug_loc    -> ".section	.debug_loc,\"\",%progbits"
      | Section_debug_abbrev -> ".section	.debug_abbrev,\"\",%progbits"
      | Section_debug_line _ -> ".section	.debug_line,\"\",%progbits"
      | Section_debug_ranges -> ".section	.debug_ranges,\"\",%progbits"
      | Section_debug_str    -> ".section	.debug_str,\"MS\",%progbits,1"
      | Section_user(s, wr, ex) ->
          sprintf ".section	\"%s\",\"a%s%s\",%%progbits"
            s (if wr then "w" else "") (if ex then "x" else "")
      | Section_ais_annotation -> sprintf ".section	\"__compcert_ais_annotations\",\"\",@note"

    let section oc sec =
      fprintf oc "	%s\n" (name_of_section sec)

(* Associate labels to floating-point constants and to symbols. *)

    let emit_constants oc lit =
      if exists_constants () then begin
         section oc lit;
         if Hashtbl.length literal64_labels > 0 then
           begin
             fprintf oc "	.align 3\n";
             Hashtbl.iter
               (fun bf lbl -> fprintf oc "%a:	.quad	0x%Lx\n" label lbl bf)
               literal64_labels
           end;
         if Hashtbl.length literal32_labels > 0 then
           begin
             fprintf oc "	.align	2\n";
             Hashtbl.iter
               (fun bf lbl ->
                  fprintf oc "%a:	.long	0x%lx\n" label lbl bf)
               literal32_labels
           end;
         reset_literals ()
      end

(* Generate code to load the address of id + ofs in register r *)

    (* let loadsymbol oc r id ofs = () *)

(* Emit .file / .loc debugging directives *)

    let print_file_line oc file line =
      print_file_line oc comment file line

(*
    let print_location oc loc =
      if loc <> Cutil.no_loc then print_file_line oc (fst loc) (snd loc)
*)

(* Add "w" suffix to 32-bit instructions if we are in 64-bit mode *)

    (* let w oc = *)
    (*   if Archi.ptr64 then output_string oc "w" *)

(* Offset part of a load or store *)

    (* let offset oc = function _ -> "offset" *)

    (* Printing of instructions *)
    let print_instruction oc = function
      | Pload (op, reg1, reg2, off) ->
        fprintf oc "	%a = *(%a *)(%a + %a)\n" register reg1 sizeOp op register reg2 coqint off

      | Pstore (op, reg, regimm, off) ->
        fprintf oc "	*(%a *)(%a + %a) = %a\n" sizeOp op register reg coqint off register_or_immediate regimm

      | Palu (op, reg, regimm) ->
        fprintf oc "	%a%a%a\n" register reg operator op register_or_immediate regimm

      | Pcmp (op, reg, regimm) -> print_cmp oc op reg regimm
      | Pjmp goto -> fprintf oc "	goto %a\n" print_label_or_ident goto
      | Pjmpcmp (op, reg, regimm, label) -> print_jump_cmp oc op reg regimm label

      | Pcall (s, _) -> fprintf oc "	call %a\n" symbol s

      | Pret -> fprintf oc "	exit\n"

      | Plabel label -> fprintf oc "%a:\n" print_label label

      | Pbuiltin _
      | Pallocframe _
      | Pfreeframe _ -> assert false

    let get_section_names name =
      let (text, lit) =
        match C2C.atom_sections name with
        | t :: l :: _ -> (t, l)
        | _    -> (Section_text, Section_literal) in
      text,lit,Section_jumptable

    let print_align oc alignment =
      fprintf oc "	.balign %d\n" alignment

    let print_jumptable oc jmptbl =
      let print_tbl oc (lbl, tbl) =
        fprintf oc "%a:\n" label lbl;
        List.iter
          (fun l -> fprintf oc "	.long	%a - %a\n"
                               print_label l label lbl)
          tbl in
      if !jumptables <> [] then
        begin
          section oc jmptbl;
          fprintf oc "	.balign 4\n";
          List.iter (print_tbl oc) !jumptables;
          jumptables := []
        end

    let print_fun_info = elf_print_fun_info

    let print_optional_fun_info _ = ()

    let print_var_info = elf_print_var_info

    let print_comm_symb oc sz name align =
      if C2C.atom_is_static name then
        fprintf oc "	.local	%a\n" symbol name;
        fprintf oc "	.comm	%a, %s, %d\n"
        symbol name
        (Z.to_string sz)
        align

    let print_instructions oc fn =
      current_function_sig := fn.fn_sig;
      List.iter (print_instruction oc) fn.fn_code


(* Data *)

    let address = if Archi.ptr64 then ".quad" else ".long"

    let print_prologue oc = ()
      (* fprintf oc "	.option %s\n" (if Archi.pic_code() then "pic" else "nopic"); *)
      (* if !Clflags.option_g then begin *)
      (*   section oc Section_text; *)
      (* end *)

    let print_epilogue oc = ()
      (* if !Clflags.option_g then begin *)
      (*   Debug.compute_gnu_file_enum (fun f -> ignore (print_file oc f)); *)
      (*   section oc Section_text; *)
      (* end *)

    let default_falignment = 2

    let cfi_startproc oc = ()
    let cfi_endproc oc = ()

  end

let sel_target () =
  (module Target:TARGET)
