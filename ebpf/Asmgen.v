(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*                  Xavier Leroy, INRIA Paris                          *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(** Translation from Mach to eBPF assembly language *)

Require Archi.
Require Import Coqlib Errors.
Require Import AST Integers Memdata.
Require Import Op Locations Mach Asm.

Local Open Scope string_scope.
Local Open Scope error_monad_scope.

(** The code generation functions take advantage of several
  characteristics of the [Mach] code generated by earlier passes of the
  compiler, mostly that argument and result registers are of the correct
  types.  These properties are true by construction, but it's easier to
  recheck them during code generation and fail if they do not hold. *)

(** Extracting integer registers. *)

Definition preg_of (r: mreg) : res preg :=
  match Asm.preg_of r with
  | Some mr => OK mr
  | _ => Error (msg "Floating numbers aren't available in eBPF")
  end.


(** Translation of conditional branches. *)

Definition transl_cbranch_sign (sign: Ctypes.signedness) (cmp: comparison) (r1: preg) (r2: preg+imm) (lbl: label) :=
  match cmp with
  | Ceq => Pjmpcmp EQ r1 r2 lbl
  | Cne => Pjmpcmp NE r1 r2 lbl
  | Clt => Pjmpcmp (LT sign) r1 r2 lbl
  | Cle => Pjmpcmp (LE sign) r1 r2 lbl
  | Cgt => Pjmpcmp (GT sign) r1 r2 lbl
  | Cge => Pjmpcmp (GE sign) r1 r2 lbl
  end.

Definition transl_cbranch (cond: condition) (args: list mreg) (lbl: label) (k: code) :=
  match cond, args with
  | Ccomp c, a1 :: a2 :: nil =>
      do r1 <- preg_of a1;
      do r2 <- preg_of a2;
      OK (transl_cbranch_sign Ctypes.Signed c r1 (inl r2) lbl :: k)

  | Ccompu c, a1 :: a2 :: nil =>
      do r1 <- preg_of a1;
      do r2 <- preg_of a2;
      OK (transl_cbranch_sign Ctypes.Unsigned c r1 (inl r2) lbl :: k)

  | Ccompimm c n, a1 :: nil =>
      do r1 <- preg_of a1;
      OK (transl_cbranch_sign Ctypes.Signed c r1 (inr n) lbl :: k)

  | Ccompuimm c n, a1 :: nil =>
      do r1 <- preg_of a1;
      OK (transl_cbranch_sign Ctypes.Unsigned c r1 (inr n) lbl :: k)

  | Ccompf _, _
  | Cnotcompf _, _
  | Ccompfs _, _
  | Cnotcompfs _, _ => Error (msg "Floating numbers aren't available in eBPF")

  | _, _ => Error(msg "Asmgen.transl_cbranch")
  end.

Definition transl_cond_sign (sign: Ctypes.signedness) (cmp: comparison) (r1: preg) (r2: preg+imm) :=
  match cmp with
  | Ceq => Pcmp EQ r1 r2
  | Cne => Pcmp NE r1 r2
  | Clt => Pcmp (LT sign) r1 r2
  | Cle => Pcmp (LE sign) r1 r2
  | Cgt => Pcmp (GT sign) r1 r2
  | Cge => Pcmp (GE sign) r1 r2
  end.

Definition transl_cond_op (cond: condition) (rd: preg) (args: list mreg) (k: code) :=
  match cond, args with
  | Ccomp c, a1 :: a2 :: nil =>
      do r1 <- preg_of a1;
      do r2 <- preg_of a2;
      OK (transl_cond_sign Ctypes.Signed c r1 (inl r2) :: k)

  | Ccompu c, a1 :: a2 :: nil =>
      do r1 <- preg_of a1;
      do r2 <- preg_of a2;
      OK (transl_cond_sign Ctypes.Unsigned c r1 (inl r2) :: k)

  | Ccompimm c n, a1 :: nil =>
      do r1 <- preg_of a1;
      OK (transl_cond_sign Ctypes.Signed c r1 (inr n) :: k)

  | Ccompuimm c n, a1 :: nil =>
      do r1 <- preg_of a1;
      OK (transl_cond_sign Ctypes.Unsigned c r1 (inr n) :: k)

  | Ccompf c, _
  | Cnotcompf c, _
  | Ccompfs c, _
  | Cnotcompfs c, _ => Error (msg "Floating numbers aren't available in eBPF")

  | _, _ =>
      Error(msg "Asmgen.transl_cond_op")
  end.

(** Translation of the arithmetic operation [r <- op(args)].
  The corresponding instructions are prepended to [k]. *)

Definition transl_op (op: operation) (args: list mreg) (res: mreg) (k: code) :=
  match op, args with
  | Omove, a1 :: nil =>
      do r <- preg_of res;
      do r1 <- preg_of a1;
      OK (Palu MOV r (inl r1) :: k)

  | Ointconst n, nil =>
      do r <- preg_of res;
      OK (Palu MOV r (inr n) :: k)

  | Oaddrstack n, nil =>
      do r <- preg_of res;

      if Ptrofs.eq_dec n Ptrofs.zero then
        OK (Palu MOV r (inl SP) :: k)
      else
        OK (Palu MOV r (inl SP) ::
            Palu ADD r (inr (Int.repr (Ptrofs.signed n))) :: k)

  | Oadd, a1 :: a2 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      do r2 <- preg_of a2;
      OK (Palu ADD r (inl r2) :: k)

  | Oaddimm n, a1 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      OK (Palu ADD r (inr n) :: k)

  | Oneg, a1 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      OK (Palu MUL r (inr (Int.repr (-1))) :: k)

  | Osub, a1 :: a2 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      do r2 <- preg_of a2;
      OK (Palu SUB r (inl r2) :: k)

  | Osubimm n, a1 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      OK (Palu SUB r (inr n) :: k)

  | Omul, a1 :: a2 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      do r2 <- preg_of a2;
      OK (Palu MUL r (inl r2) :: k)

  | Omulimm n, a1 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      OK (Palu MUL r (inr n) :: k)

  | Odivu, a1 :: a2 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      do r2 <- preg_of a2;
      OK (Palu DIV r (inl r2) :: k)

  | Odivuimm n, a1 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      OK (Palu DIV r (inr n) :: k)

  | Omodu, a1 :: a2 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      do r2 <- preg_of a2;
      OK (Palu MOD r (inl r2) :: k)

  | Omoduimm n, a1 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      OK (Palu MOD r (inr n) :: k)

  | Oand, a1 :: a2 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      do r2 <- preg_of a2;
      OK (Palu AND r (inl r2) :: k)

  | Oandimm n, a1 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      OK (Palu AND r (inr n) :: k)

  | Oor, a1 :: a2 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      do r2 <- preg_of a2;
      OK (Palu OR r (inl r2) :: k)

  | Oorimm n, a1 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      OK (Palu OR r (inr n) :: k)

  | Oxor, a1 :: a2 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      do r2 <- preg_of a2;
      OK (Palu XOR r (inl r2) :: k)

  | Oxorimm n, a1 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      OK (Palu XOR r (inr n) :: k)

  | Oshl, a1 :: a2 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      do r2 <- preg_of a2;
      OK (Palu LSH r (inl r2) :: k)

  | Oshlimm n, a1 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      OK (Palu LSH r (inr n) :: k)

  | Oshr, a1 :: a2 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      do r2 <- preg_of a2;
      OK (Palu RSH r (inl r2) :: k)

  | Oshrimm n, a1 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      OK (Palu RSH r (inr n) :: k)

  | Oshru, a1 :: a2 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      do r2 <- preg_of a2;
      OK (Palu ARSH r (inl r2) :: k)

  | Oshruimm n, a1 :: nil =>
      assertion (mreg_eq a1 res);
      do r <- preg_of res;
      OK (Palu ARSH r (inr n) :: k)

  | Ocmp cmp, _ =>
      do r <- preg_of res;
      transl_cond_op cmp r args k

  (*c Following operations aren't available in eBPF, and will throw errors in this step *)
  | Oaddrsymbol s ofs, nil => Error (msg "global variables are not available in eBPF")

  | Ocast8signed, a1 :: nil => Error (msg "cast8signed is not available in eBPF")
  | Ocast16signed, a1 :: nil => Error (msg "cast16signed is not available in eBPF")

  | Omulhs, a1 :: a2 :: nil => Error (msg "mulhs is not available in eBPF")
  | Omulhu, a1 :: a2 :: nil => Error (msg "mulhu is not available in eBPF")
  | Odiv, a1 :: a2 :: nil => Error (msg "div is not available in eBPF")
  | Omod, a1 :: a2 :: nil => Error (msg "mod is not available in eBPF")
  | Oshrximm n, a1 :: nil => Error (msg "shrximm is not available in eBPF")

  (* [Omakelong] and [Ohighlong] should not occur *)
  | Olowlong, a1 :: nil => Error (msg "lowlong is not available in eBPF")

  | Ofloatconst _, _
  | Osingleconst _, nil

  | Onegf, _
  | Oabsf, _
  | Oaddf, _
  | Osubf, _
  | Omulf, _
  | Odivf, _

  | Onegfs, _
  | Oabsfs, _
  | Oaddfs, _
  | Osubfs, _
  | Omulfs, _
  | Odivfs, _

  | Osingleoffloat, _
  | Ofloatofsingle, _

  | Ointoffloat, _
  | Ointuoffloat, _
  | Ofloatofint, _
  | Ofloatofintu, _
  | Ointofsingle, _
  | Ointuofsingle, _
  | Osingleofint, _
  | Osingleofintu, _

  | Olongoffloat, _
  | Olonguoffloat, _
  | Ofloatoflong, _
  | Ofloatoflongu, _
  | Olongofsingle, _
  | Olonguofsingle, _
  | Osingleoflong, _
  | Osingleoflongu, _ => Error (msg "Floating numbers aren't available in eBPF")

  | _, _ => Error (msg "Asmgen.transl_op")
  end.

(** Accessing data in the stack frame. *)

Definition transl_typ (typ: typ): res (sizeOp) :=
  match typ with
  | Tint | Tany32 => OK Word

  | Tsingle | Tfloat => Error (msg "Floating numbers aren't available in eBPF")

  | _ => Error (msg "Asmgen.transl_memory_access")
  end.


(** Translation of memory accesses: loads, and stores. *)

Definition transl_memory_access (chunk: memory_chunk): res (sizeOp) :=
  match chunk with
  | Mint8unsigned => OK Byte

  | Mint16unsigned => OK HalfWord

  | Mint32 | Many32 => OK Word

  | Mfloat32 | Mfloat64 => Error (msg "Floating numbers aren't available in eBPF")

  | _ => Error (msg "Asmgen.transl_memory_access")
  end.

Definition transl_load (chunk: memory_chunk) (addr: addressing)
           (args: list mreg) (dst: mreg) (k: code): res (list instruction) :=
  match addr, args with
  | Aindexed ofs, a1 :: nil =>
      do r <- preg_of dst;
      do r1 <- preg_of a1;
      do size <- transl_memory_access chunk;
      OK (Pload size r r1 ofs :: k)

  | Ainstack ofs, nil =>
      do r <- preg_of dst;
      do size <- transl_memory_access chunk;
      OK (Pload size r SP ofs :: k)

  | _, _ => Error(msg "transl_load.Mint32")
  end.

Definition transl_store (chunk: memory_chunk) (addr: addressing)
           (args: list mreg) (src: mreg) (k: code): res (list instruction) :=
  match addr, args with
  | Aindexed ofs, a1 :: nil =>
      do r <- preg_of src;
      do r1 <- preg_of a1;
      do size <- transl_memory_access chunk;
      OK (Pstore size r (inl r1) ofs :: k)

  | Ainstack ofs, nil =>
      do r <- preg_of src;
      do size <- transl_memory_access chunk;
      OK (Pstore size r (inl SP) ofs :: k)

  | _, _ => Error(msg "transl_store.Mint32")
  end.

(** Translation of a Mach instruction. *)

Definition transl_instr (f: Mach.function) (i: Mach.instruction)
                        (ep: bool) (k: code): res (list instruction) :=
  match i with
  | Mgetstack ofs ty dst =>
      do r <- preg_of dst;
      do size <- transl_typ ty;
      OK (Pload size r SP ofs :: k)

  | Msetstack src ofs ty =>
      do r <- preg_of src;
      do size <- transl_typ ty;
      OK (Pstore size r (inl SP) ofs :: k)

  | Mgetparam _ _ _ => Error (msg "Functions with more than 5 arguments aren't available in eBPF")

  | Mop op args res => transl_op op args res k

  | Mload chunk addr args dst => transl_load chunk addr args dst k

  | Mstore chunk addr args src => transl_store chunk addr args src k

  | Mcall sig (inr symb) => OK (Pcall symb sig :: k)

  | Mtailcall sig (inr symb) =>
      OK (Pfreeframe f.(fn_stacksize) f.(fn_link_ofs) :: Pjmp (inr symb) :: k)

  | Mcall sig (inl r)
  | Mtailcall sig (inl r) => Error (msg "Call from function pointer aren't available in eBPF")

  | Mbuiltin ef args res => Error (msg "No builtins have been implemented")

  | Mlabel lbl => OK (Plabel lbl :: k)

  | Mgoto lbl => OK (Pjmp (inl lbl) :: k)

  | Mcond cond args lbl => transl_cbranch cond args lbl k

  | Mjumptable arg tbl => Error (msg "Mjumptable")
  (*     do r <- ireg_of arg; *)
  (*     OK (Pbtbl r tbl :: k) *)

  | Mreturn => OK (Pfreeframe f.(fn_stacksize) f.(fn_link_ofs) :: Pret :: k)
  end.

(** Translation of a code sequence *)

Definition it1_is_parent (before: bool) (i: Mach.instruction) : bool :=
  match i with
  | Msetstack src ofs ty => before
  | Mgetparam ofs ty dst => negb (mreg_eq dst I0)
  | Mop op args res => before && negb (mreg_eq res I0)
  | _ => false
  end.

(** This is the naive definition that we no longer use because it
  is not tail-recursive.  It is kept as specification. *)

Fixpoint transl_code (f: Mach.function) (il: list Mach.instruction) (it1p: bool) :=
  match il with
  | nil => OK nil
  | i1 :: il' =>
      do k <- transl_code f il' (it1_is_parent it1p i1);
      transl_instr f i1 it1p k
  end.

(** This is an equivalent definition in continuation-passing style
  that runs in constant stack space. *)

Fixpoint transl_code_rec (f: Mach.function) (il: list Mach.instruction)
                         (it1p: bool) (k: code -> res code) :=
  match il with
  | nil => k nil
  | i1 :: il' =>
      transl_code_rec f il' (it1_is_parent it1p i1)
        (fun c1 => do c2 <- transl_instr f i1 it1p c1; k c2)
  end.

Definition transl_code' (f: Mach.function) (il: list Mach.instruction) (it1p: bool) :=
  transl_code_rec f il it1p (fun c => OK c).

(** Translation of a whole function.  Note that we must check
  that the generated code contains less than [2^32] instructions,
  otherwise the offset part of the [PC] code pointer could wrap
  around, leading to incorrect executions. *)

Definition transl_function (f: Mach.function) :=
  do c <- transl_code' f f.(Mach.fn_code) true;
  OK (mkfunction f.(Mach.fn_sig)
    (Pallocframe f.(fn_stacksize) f.(fn_link_ofs) :: c)).

Definition transf_function (f: Mach.function) : res Asm.function :=
  do tf <- transl_function f;
  if zlt Ptrofs.max_unsigned (list_length_z tf.(fn_code))
  then Error (msg "code size exceeded")
  else OK tf.

Definition transf_fundef (f: Mach.fundef) : res Asm.fundef :=
  transf_partial_fundef transf_function f.

Definition transf_program (p: Mach.program) : res Asm.program :=
  transform_partial_program transf_fundef p.
