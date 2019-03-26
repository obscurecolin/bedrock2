Require Import lib.LibTacticsMin.
Require Import riscv.Utility.Monads. Require Import riscv.Utility.MonadNotations.
Require Import coqutil.Macros.unique.
Require Import compiler.FlatImp.
Require Import Coq.Lists.List.
Import ListNotations.
Require Import Coq.ZArith.ZArith.
Require Import riscv.Spec.Machine.
Require Import riscv.Spec.Decode.
Require Import riscv.Spec.PseudoInstructions.
Require Import riscv.Platform.RiscvMachine.
Require Import riscv.Spec.Execute.
Require Import riscv.Platform.Run.
Require Import riscv.Platform.Memory.
Require Import riscv.Utility.PowerFunc.
Require Import riscv.Utility.ListLib.
Require Import coqutil.Decidable.
Require Import Coq.Program.Tactics.
Require Import Coq.Bool.Bool.
Require Import riscv.Utility.InstructionCoercions.
Require Import riscv.Spec.Primitives.
Require Import Coq.micromega.Lia.
Require Import riscv.Utility.div_mod_to_quot_rem.
Require Import compiler.util.Misc.
Require Import riscv.Utility.Utility.
Require Import coqutil.Z.BitOps.
Require Import compiler.util.Common.
Require Import riscv.Utility.Utility.
Require Import riscv.Utility.MkMachineWidth.
Require Import riscv.Utility.runsToNonDet.
Require Import compiler.FlatToRiscvDef.
Require Import compiler.GoFlatToRiscv.
Require Import compiler.EmitsValid.
Require Import compiler.SeparationLogic.
Require Import bedrock2.Scalars.
Require Import compiler.Simp.
Require Import compiler.SimplWordExpr.
Require Import bedrock2.ptsto_bytes.
Require Import compiler.RiscvWordProperties.
Require Import compiler.eqexact.
Require Import compiler.on_hyp_containing.
Require Import compiler.PushPullMod.
Require coqutil.Map.Empty_set_keyed_map.
Require Import coqutil.Z.bitblast.
Require Import riscv.Utility.prove_Zeq_bitwise.

Local Open Scope ilist_scope.
Local Open Scope Z_scope.

Set Implicit Arguments.

Section TODO.
  Context {K V: Type}.
  Context {M: map.map K V}.
  Axiom put_put_same: forall k v1 v2 m, map.put (map.put m k v1) k v2 = map.put m k v2.
End TODO.

Axiom TODO: False.

Module Import FlatToRiscv.
  Export FlatToRiscvDef.FlatToRiscvDef.

  Class parameters := {
    def_params :> FlatToRiscvDef.parameters;

    locals :> map.map Register word;
    mem :> map.map word byte;

    M: Type -> Type;
    MM :> Monad M;
    RVM :> RiscvProgram M word;
    PRParams :> PrimitivesParams M (RiscvMachine Register actname);

    ext_spec : list (mem * actname * list word * (mem * list word)) ->
               mem -> actname -> list word -> (mem -> list word -> Prop) -> Prop;

    (* An abstract predicate on the low-level state, which can be chosen by authors of
       extensions. The compiler will ensure that this guarantee holds before each external
       call. *)
    ext_guarantee: RiscvMachine Register actname -> Prop;
  }.

  Instance syntax_params{p: parameters}: Syntax.parameters := {|
    Syntax.varname := Register;
    Syntax.funname := Empty_set;
    Syntax.actname := actname;
  |}.

  Instance Semantics_params{p: parameters}: Semantics.parameters := {|
    Semantics.syntax := syntax_params;
    Semantics.ext_spec := ext_spec;
    Semantics.funname_eqb := Empty_set_rect _;
    Semantics.funname_env := Empty_set_keyed_map.map;
  |}.

  Class assumptions{p: parameters} := {
    word_riscv_ok :> word.riscv_ok (@word W);
    locals_ok :> map.ok locals;
    mem_ok :> map.ok mem;
    actname_eq_dec :> DecidableEq actname;
    PR :> Primitives PRParams;

    (* For authors of extensions, a freely choosable ext_guarantee sounds too good to be true!
       And indeed, there are two restrictions:
       The first restriction is that ext_guarantee needs to be preservable for the compiler: *)
    ext_guarantee_preservable: forall (m1 m2: RiscvMachine Register actname),
        ext_guarantee m1 ->
        map.same_domain m1.(getMem) m2.(getMem) ->
        m1.(getLog) = m2.(getLog) ->
        ext_guarantee m2;

    (* And the second restriction is part of the correctness requirement for compilation of
       external calls: Every compiled external call has to preserve ext_guarantee *)
    compile_ext_call_correct: forall (initialL: RiscvMachine Register actname) action postH newPc insts
        (argvars resvars: list Register) initialMH R,
      insts = compile_ext_call resvars action argvars ->
      newPc = word.add initialL.(getPc) (word.mul (word.of_Z 4) (word.of_Z (Zlength insts))) ->
      Forall valid_register argvars ->
      Forall valid_register resvars ->
      (program initialL.(getPc) insts * eq initialMH * R)%sep initialL.(getMem) ->
      initialL.(getNextPc) = word.add initialL.(getPc) (word.of_Z 4) ->
      ext_guarantee initialL ->
      exec map.empty (SInteract resvars action argvars)
           initialL.(getLog) initialMH initialL.(getRegs) postH ->
      runsTo (mcomp_sat (run1 iset)) initialL
             (fun finalL =>
                  (* external calls can't modify the memory for now *)
                  postH finalL.(getLog) initialMH finalL.(getRegs) /\
                  finalL.(getPc) = newPc /\
                  finalL.(getNextPc) = add newPc (ZToReg 4) /\
                  (program initialL.(getPc) insts * eq initialMH * R)%sep finalL.(getMem) /\
                  ext_guarantee finalL);
  }.

End FlatToRiscv.

Local Unset Universe Polymorphism. (* for Add Ring *)

Lemma mod_mod_remove_outer: forall a m n,
    0 < m < n ->
    n mod m = 0 ->
    (a mod m) mod n = a mod m.
Proof.
  intros *. intros [A B] C. apply Z.mod_small.
  pose proof (Z.mod_pos_bound a m A). lia.
Qed.

Lemma mod_mod_remove_inner: forall a m n,
    0 < n < m ->
    m mod n = 0 ->
    (a mod m) mod n = a mod n.
Proof.
  intros. rewrite <- Znumtheory.Zmod_div_mod; try lia.
  unfold Z.divide.
  apply Zmod_divides in H0; [|lia].
  destruct H0. subst m.
  exists x. lia.
Qed.

Lemma div_mul_same: forall a b,
    b <> 0 ->
    a / b * b = a - a mod b.
Proof.
  intros.
  pose proof (Zmod_eq_full a b H).
  lia.
Qed.

Definition signExtend3(l n: Z): Z := n - (Z.b2z (Z.testbit n (l - 1))) * 2 ^ l.

Lemma signExtend_alt3: forall l n,
    signExtend l n = signExtend3 l n.
Proof.
  intros.
  unfold signExtend, signExtend3.
  destruct (BinInt.Z.testbit n (l - 1)).
  - change (Z.b2z true) with 1.
    (* TODO does not hold any more *)
Admitted.

Definition mask(x start eend: Z): Z :=
  (x - x mod 2 ^ start) mod 2 ^ eend.

Lemma sub_mod_exists_q: forall v m,
    0 < m ->
    exists q, v - v mod m = m * q.
Proof.
  intros.
  assert (m <> 0) as A by lia.
  pose proof (Z.div_mod v m A) as P.
  exists (v / m).
(*
    v - v mod m = m * (v / m)

  lia.

Search (?a = ?b * (?a / ?b) + ?a mod ?b).
Search "eucl" Z.
*)
Abort.

Lemma sub_mod_exists_q: forall v m,
    0 < m ->
    exists q, v - v mod m = m * q.
Proof.
  intros.
  apply (Zmod_divides (v - v mod m) m); [lia|].
  rewrite <- Zminus_mod_idemp_l.
  rewrite Z.sub_diag.
  rewrite Z.mod_0_l; lia.
Qed.

Lemma shiftr_spec'': forall a n m : Z,
    Z.testbit (Z.shiftr a n) m = (0 <=? m) &&  Z.testbit a (m + n).
Proof.
  intros.
  destruct (Z.leb_spec 0 m).
  - apply Z.shiftr_spec. assumption.
  - rewrite Z.testbit_neg_r; trivial.
Qed.

Lemma shiftr_spec': forall a n m : Z,
    Z.testbit (Z.shiftr a n) m = negb (m <? 0) &&  Z.testbit a (m + n).
Proof.
  intros.
  destruct (Z.ltb_spec m 0).
  - rewrite Z.testbit_neg_r; trivial.
  - apply Z.shiftr_spec. assumption.
Qed.

Lemma mask_app_plus: forall v i j k,
    0 <= i ->
    i <= j ->
    j <= k ->
    mask v i j + mask v j k = mask v i k.
Proof.
  intros. unfold mask.
  do 2 rewrite <- div_mul_same by (apply Z.pow_nonzero; lia).
  rewrite <-! Z.land_ones by lia.
  rewrite <-! Z.shiftl_mul_pow2 by lia.
  rewrite <- BitOps.or_to_plus; Z.bitblast.
Qed.

Ltac simpl_pow2_products :=
  repeat match goal with
         | |- context [ 2 ^ ?a * 2 ^ ?b ] =>
           match isZcst a with true => idtac end;
           match isZcst b with true => idtac end;
           let c := eval cbv in (a + b) in change (2 ^ a * 2 ^ b) with (2 ^ c)
         end.

Ltac simpl_Zcsts :=
  repeat match goal with
         | |- context [?op ?a ?b] =>
           match isZcst a with true => idtac end;
           match isZcst b with true => idtac end;
           match op with
           | Z.add => idtac
           | Z.sub => idtac
           | Z.mul => idtac
           end;
           let r := eval cbv in (op a b) in change (op a b) with r
         end.

Section compile_lit64bit_equiv.
  Context {width: Z} {word: word.word width} {word_ok: word.ok word}.
  Hypothesis W: width = 64.

  Definition compile_lit_64bit_semantics(w: Z): word :=
    let mid := signExtend 12 (bitSlice (signExtend 32 (bitSlice w 32 64)) 0 12) in
    let hi := signExtend 32 (signExtend 32 (bitSlice w 32 64) - mid) in
    (word.add
       (word.slu
          (word.add
             (word.slu
                (word.add
                   (word.slu
                      (word.add
                         (word.of_Z hi)
                         (word.of_Z mid))
                      (word.of_Z 10))
                   (word.of_Z (bitSlice w 22 32)))
                (word.of_Z 11))
             (word.of_Z (bitSlice w 11 22)))
          (word.of_Z 11))
       (word.of_Z (bitSlice w 0 11))).

  Lemma compile_lit_64bit_correct: forall v,
      v mod 2 ^ 64 = word.unsigned (compile_lit_64bit_semantics (v  mod 2 ^ 64)).
  Proof.
    intros.
    unfold compile_lit_64bit_semantics.
    rewrite word.unsigned_add.
    assert (word.unsigned (word.of_Z 11) = 11) as A. {
      rewrite word.unsigned_of_Z. rewrite W. reflexivity.
    }
    assert (word.unsigned (word.of_Z 10) = 10) as A'. {
      rewrite word.unsigned_of_Z. rewrite W. reflexivity.
    }
    rewrite word.unsigned_slu by (rewrite A, W; reflexivity).
    rewrite word.unsigned_add.
    rewrite word.unsigned_slu by (rewrite A, W; reflexivity).
    rewrite word.unsigned_add.
    rewrite word.unsigned_slu by (rewrite A', W; reflexivity).
    rewrite word.unsigned_add.
    rewrite A, A', W.
    rewrite! Z.shiftl_mul_pow2 by lia.
    rewrite! word.unsigned_of_Z.
    rewrite W.
    rewrite! bitSlice_alt by lia.
    unfold bitSlice'.
    unfold signExtend.
    Set Printing Depth 100000.
    simpl_Zcsts.
    change (2 ^ 0) with 1.
    rewrite! Z.div_1_r.
  Admitted. (*
    match goal with
    | |- context [Z.b2z ?x] => remember (Z.b2z x) as b1
    end.
    match goal with
    | |- context [Z.b2z ?x] => remember (Z.b2z x) as b2
    end.
    push_mod. rewrite! Zmod_mod.

    repeat match goal with
           | |- context [(?a mod ?m1) mod ?m2] =>
             rewrite (@mod_mod_remove_inner a m1 m2) by (repeat split)
           end.

Ltac pull_mod_step ::=
  match goal with
  | |- context [ (?op (?a mod ?m) (?b mod ?m)) mod ?m ] =>
    mod_free a m;
    mod_free b m;
    match op with
    | Z.add => rewrite <- (Zplus_mod a b m)
    | Z.sub => rewrite <- (Zminus_mod a b m)
    | Z.mul => rewrite <- (Zmult_mod a b m)
    end
(*     idtac a "======" op "======" b*)
(*
  | |- context [(?a mod ?m1) mod ?m2] =>
    mod_free a m2;
    rewrite (@mod_mod_remove_outer a m1 m2) by (repeat split);
    idtac m1 "_______" m2
*)
  end.

    remember (v mod 2 ^ 64 / 2 ^ 32) as a.
    remember (v mod 2 ^ 64 / 2 ^ 22) as b.
    remember (v mod 2 ^ 64 / 2 ^ 11) as c.
    pull_mod.
    rewrite !Z.mul_add_distr_r.
    rewrite !Z.mul_sub_distr_r.
    rewrite <-!Z.mul_assoc.
    simpl_pow2_products.
    rewrite <-! Zmult_mod_distr_r.
    subst a b c.
    rewrite !div_mul_same by (cbv;  discriminate).
    simpl_pow2_products.
    push_mod. rewrite! Zmod_mod.
    remember (v mod 2 ^ 64 / 2 ^ 32) as hi.
    repeat match goal with
           | |- context [(?a mod ?m1) mod ?m2] =>
             rewrite (@mod_mod_remove_inner a m1 m2) by (repeat split)
           end.
    pull_mod.
    rewrite !Z.mul_add_distr_r.
    rewrite !Z.mul_sub_distr_r.
    simpl_pow2_products.
    match goal with
    | |- ?x mod _ = ?y mod _ => ring_simplify x y (* +/- 2 ^ 63 cancels out *)
    end.
    change 4294967296 with (2 ^ 32).
    change 18446744073709551616 with (2 ^ 64).
    rewrite <- Zmult_mod_distr_l.
    simpl_pow2_products.
    rewrite !(Z.mul_comm (2 ^ 32)) in *.
    rewrite Z.mul_sub_distr_r.
    remember (hi * 2 ^ 32) as hii. subst hi.
    rewrite div_mul_same in Heqhii by lia.
    subst hii.
    repeat match goal with
           | |- context [(?a mod ?m1) mod ?m2] =>
             rewrite (@mod_mod_remove_inner a m1 m2) by (repeat split)
           end.
    push_mod. rewrite! Zmod_mod.
    repeat match goal with
           | |- context [(?a mod ?m1) mod ?m2] =>
             (rewrite (@mod_mod_remove_inner a m1 m2) by (repeat split)) ||
             (rewrite (@mod_mod_remove_outer a m1 m2) by (repeat split))
           end.
    push_mod.
    rewrite Z_mod_same_full. rewrite Z.mul_0_l. rewrite Zmod_0_l. rewrite Z.sub_0_r.
    rewrite! Zmod_mod.
    pull_mod.
    match goal with
    | |- ?x mod _ = ?y mod _ => ring_simplify x y
    end.
    clear b1 Heqb1 b2 Heqb2.
    replace (v - v mod 2 ^ 32 + (v - v mod 2 ^ 22) mod 2 ^ 32 + (v - v mod 2 ^ 11) mod 2 ^ 22 +
             v mod 2 ^ 11)
      with ((v - v mod 2 ^ 32) + ((v - v mod 2 ^ 22) mod 2 ^ 32 + (v - v mod 2 ^ 11) mod 2 ^ 22 +
             v mod 2 ^ 11)) by lia.
    rewrite <- Zplus_mod_idemp_l.
    rewrite !Z.add_assoc.
    repeat match goal with
    | |- context [ (?x - ?x mod 2 ^ ?start) mod 2 ^ ?eend ] =>
      change ((x - x mod 2 ^ start) mod 2 ^ eend) with (mask x start eend)
    end.
    pose proof (eq_refl : mask v 0 11 = mask v 0 11) as E.
    unfold mask at 2 in E. change (2 ^ 0) with 1 in E. rewrite Z.mod_1_r in E.
    rewrite Z.sub_0_r in E. rewrite <- E. clear E.
    replace (mask v 32 64 + mask v 22 32 + mask v 11 22 + mask v 0 11)
      with  (mask v 0 11 + mask v 11 22 + mask v 22 32 + mask v 32 64) by lia.
    rewrite! mask_app_plus by lia.
    unfold mask.
    rewrite Zmod_mod.
    change (2 ^ 0) with 1. rewrite Z.mod_1_r. rewrite Z.sub_0_r.
    reflexivity.
  Qed.
*)
End compile_lit64bit_equiv.


Section FlatToRiscv1.
  Context {p: unique! FlatToRiscv.parameters}.
  Context {h: unique! FlatToRiscv.assumptions}.

  Notation var := Z (only parsing).

  Definition trace := list (LogItem actname).

  Local Notation RiscvMachineL := (RiscvMachine Register actname).

  Ltac word_cst w :=
    match w with
    | word.of_Z ?x => let b := isZcst x in
                      match b with
                      | true => x
                      | _ => constr:(NotConstant)
                      end
    | _ => constr:(NotConstant)
    end.

  Definition word_ring_morph := word.ring_morph (word := word).
  Definition word_ring_theory := word.ring_theory (word := word).

  Hint Rewrite
    word_ring_morph.(morph_add)
    word_ring_morph.(morph_sub)
    word_ring_morph.(morph_mul)
    word_ring_morph.(morph_opp)
  : rew_word_morphism.

  Add Ring wring : word_ring_theory
      (preprocess [autorewrite with rew_word_morphism],
       morphism word_ring_morph,
       constants [word_cst]).

  Hint Rewrite @Zlength_nil @Zlength_cons @Zlength_app: rew_Zlength.

  Lemma reduce_eq_to_sub_and_lt: forall (y z: word) {T: Type} (thenVal elseVal: T),
      (if word.eqb y z then thenVal else elseVal) =
      (if word.ltu (word.sub y z) (word.of_Z 1) then thenVal else elseVal).
  Proof.
  Admitted.

  (* TODO is there a principled way of writing such proofs? *)
  Lemma reduce_eq_to_sub_and_lt_old: forall (y z: word) {T: Type} (thenVal elseVal: T),
    (if ltu (sub y  z) (fromImm 1) then thenVal else elseVal) =
    (if reg_eqb y z        then thenVal else elseVal).
  Proof. (*
    intros. destruct (weq y z).
    - subst z. unfold wminus. rewrite wminus_inv.
      destruct (wlt_dec (wzero wXLEN) $1); [reflexivity|].
      change (wzero wXLEN) with (natToWord wXLEN 0) in n. unfold wlt in n.
      exfalso. apply n.
      do 2 rewrite wordToN_nat. rewrite roundTrip_0.
      clear.
      destruct wXLEN as [|w1] eqn: E.
      + unfold wXLEN in *. destruct bitwidth; discriminate.
      + rewrite roundTrip_1. simpl. constructor.
    - destruct (@wlt_dec wXLEN (y ^- z) $ (1)) as [E|NE]; [|reflexivity].
      exfalso. apply n. apply sub_0_eq.
      unfold wlt in E.
      do 2 rewrite wordToN_nat in E.
      clear -E.
      destruct wXLEN as [|w1] eqn: F.
      + unfold wXLEN in *. destruct bitwidth; discriminate.
      + rewrite roundTrip_1 in E.
        simpl in E. apply N.lt_1_r in E. change 0%N with (N.of_nat 0) in E.
        apply Nnat.Nat2N.inj in E. rewrite <- (roundTrip_0 (S w1)) in E.
        apply wordToNat_inj in E.
        exact E.
  Qed.
*)
  Admitted.

  (*
  Lemma wlshift_bitSlice_plus: forall (sz1 sz2: Z) v,
      (0 <= sz1)%Z ->
      (0 <= sz2)%Z ->
      wlshift (ZToWord wXLEN (bitSlice v sz1 (sz1 + sz2))) (Z.to_nat sz1)
      ^+ ZToWord wXLEN (bitSlice v 0 sz1)
      = ZToWord wXLEN (bitSlice v 0 (sz1 + sz2)).
  Proof.
    intros. rewrite wlshift_alt.
    rewrite wlshift_mul_Zpow2 by assumption.
    rewrite <- ZToWord_mult.
    rewrite <- ZToWord_plus.
    f_equal.
    apply bitSlice_split; assumption.
  Qed.
  *)

  (*
  Context {Name: NameWithEq}.

  (* If we made it a definition instead, destructing an if on "@dec (@eq (@var Name) x x0)"
     (from this file), where a "@dec (@eq (@Reg Name) x x0)" (from another file, Riscv.v)
     is in the context, will not recognize that these two are the same (they both reduce to
     "@dec (@eq var x x0)", which is annoying. *)
  Notation var := var.
  Existing Instance eq_name_dec.
   *)

  (* Set Printing Projections.
     Uncaught anomaly when stepping through proofs :(
     https://github.com/coq/coq/issues/6257 *)

  Arguments Z.mul: simpl never.
  Arguments Z.add: simpl never.
  Arguments run1: simpl never.

  Ltac ensure_is_nat_rel R :=
    match R with
    | ?P /\ ?Q => ensure_is_nat_rel P; ensure_is_nat_rel Q
    | ?P \/ ?Q => ensure_is_nat_rel P; ensure_is_nat_rel Q
    | @eq nat _ _  => idtac (* can't use %nat here because = is polymorphic *)
    | (_ <  _)%nat => idtac
    | (_ <= _)%nat => idtac
    | (_ >  _)%nat => idtac
    | (_ >= _)%nat => idtac
    end.

  Lemma pow2_wXLEN_4: 4 < 2 ^ XLEN.
  Proof.
    unfold XLEN, MachineWidth_XLEN.
    pose proof (@word.width_pos _ _ word_ok).
    pose proof (Z.pow_gt_1 2 width).
    (* TODO doesn't hold, if we want this we'll have to add a stronger bound to Words,
       or somewhere else *)
  Admitted.

  Ltac nat_rel_with_words_pre :=
    match goal with
    | |- ?P => ensure_is_nat_rel P
    end(*;
    repeat match goal with
           | IsMem: Memory.Memory ?M _, m: ?M |- _ =>
             unique pose proof (@Memory.memSize_bound M _ IsMem m)
           end;
    pose proof pow2_wXLEN_4;
    rewrite? wordToNat_wplus in *;
    rewrite? wordToNat_natToWord_eqn in * *).

  Ltac nat_rel_with_words :=
    nat_rel_with_words_pre(*;
    nat_div_mod_to_quot_rem;
    nia *).

  Definition divisibleBy4(x: word): Prop := (word.unsigned x) mod 4 = 0.

  Definition divisibleBy4'(x: word): Prop := word.modu x (word.of_Z 4) = word.of_Z 0.

  Lemma four_fits: 4 < 2 ^ width.
  Proof.
    destruct width_cases as [C | C]; rewrite C; reflexivity.
  Qed.

  Ltac div4_sidecondition :=
    pose proof four_fits;
    rewrite ?word.unsigned_of_Z, ?Z.mod_small;
    lia.

  Lemma divisibleBy4_alt(x: word): divisibleBy4 x -> divisibleBy4' x.
  Proof.
    intro H. unfold divisibleBy4, divisibleBy4' in *.
    apply word.unsigned_inj.
    rewrite word.unsigned_modu_nowrap by div4_sidecondition.
    replace (word.unsigned (word.of_Z 4)) with 4 by div4_sidecondition.
    rewrite H.
    div4_sidecondition.
  Qed.

  Lemma unsigned_of_Z_4: word.unsigned (word.of_Z (word := word) 4) = 4.
  Proof. div4_sidecondition. Qed.

  Lemma unsigned_of_Z_0: word.unsigned (word.of_Z (word := word) 0) = 0.
  Proof. div4_sidecondition. Qed.

  Lemma divisibleBy4_add_4_r(x: word)
    (D: divisibleBy4 x):
    divisibleBy4 (word.add x (word.of_Z 4)).
  Proof.
    unfold divisibleBy4 in *.
    rewrite word.unsigned_add.
    rewrite <- Znumtheory.Zmod_div_mod.
    - rewrite Zplus_mod. rewrite D. rewrite unsigned_of_Z_4. reflexivity.
    - lia.
    - destruct width_cases as [C | C]; rewrite C; reflexivity.
    - unfold Z.divide. exists (2 ^ width / 4).
      destruct width_cases as [C | C]; rewrite C; reflexivity.
  Qed.

  Lemma divisibleBy4_admit(x y: word):
    divisibleBy4 x ->
    divisibleBy4 y.
  Admitted.

  Ltac solve_divisibleBy4 :=
    lazymatch goal with
    | |- divisibleBy4 _ => idtac
    | |- _ => fail "not a divisibleBy4 goal"
    end;
    solve [eapply divisibleBy4_admit; eassumption (* TODO *) ].

  Ltac simpl_modu4_0 :=
    simpl;
    match goal with
    | |- context [word.eqb ?a ?b] =>
      rewrite (word.eqb_eq a b) by (apply divisibleBy4_alt; solve_divisibleBy4)
    end;
    simpl.

  Arguments LittleEndian.combine: simpl never.

  Ltac simulate''_step :=
    first (* not everyone wants these: *)
          [ eapply go_loadByte       ; [sidecondition..|]
          | eapply go_storeByte      ; [sidecondition..|]
          | eapply go_loadHalf       ; [sidecondition..|]
          | eapply go_storeHalf      ; [sidecondition..|]
          | eapply go_loadWord       ; [sidecondition..|]
          | eapply go_storeWord      ; [sidecondition..|]
          | eapply go_loadDouble     ; [sidecondition..|]
          | eapply go_storeDouble    ; [sidecondition..|]
          (* reuse defaults which everyone wants: *)
          | simulate_step
          | simpl_modu4_0 ].

  Ltac simulate'' := repeat simulate''_step.

  Lemma go_load: forall sz x a (addr v: word) initialL post f,
      valid_register x ->
      valid_register a ->
      map.get initialL.(getRegs) a = Some addr ->
      Memory.load sz (getMem initialL) addr = Some v ->
      mcomp_sat (f tt)
                (withRegs (map.put initialL.(getRegs) x v) initialL) post ->
      mcomp_sat (Bind (execute (compile_load sz x a 0)) f) initialL post.
  Proof.
    unfold compile_load, Memory.load, Memory.load_Z, Memory.bytes_per.
    destruct width_cases as [E | E];
      (* note: "rewrite E" does not work because "width" also appears in the type of "word",
         but we don't need to rewrite in the type of word, only in the type of the tuple,
         which works if we do it before intro'ing it *)
      (destruct (width =? 32) eqn: E'; [apply Z.eqb_eq in E' | apply Z.eqb_neq in E']);
      try congruence;
      clear E';
      [set (nBytes := 4%nat) | set (nBytes := 8%nat)];
      replace (Z.to_nat ((width + 7) / 8)) with nBytes by (subst nBytes; rewrite E; reflexivity);
      subst nBytes;
      intros; destruct sz; try solve [
        unfold execute, ExecuteI.execute, ExecuteI64.execute, translate, DefaultRiscvState,
        Memory.load, Memory.load_Z in *;
        simp; simulate''; simpl; simpl_word_exprs word_ok;
          try eassumption].
  Qed.

  Lemma go_store: forall sz x a (addr v: word) initialL m' post f,
      valid_register x ->
      valid_register a ->
      map.get initialL.(getRegs) x = Some v ->
      map.get initialL.(getRegs) a = Some addr ->
      Memory.store sz (getMem initialL) addr v = Some m' ->
      mcomp_sat (f tt) (withMem m' initialL) post ->
      mcomp_sat (Bind (execute (compile_store sz a x 0)) f) initialL post.
  Proof.
    unfold compile_store, Memory.store, Memory.store_Z, Memory.bytes_per;
    destruct width_cases as [E | E];
      (* note: "rewrite E" does not work because "width" also appears in the type of "word",
         but we don't need to rewrite in the type of word, only in the type of the tuple,
         which works if we do it before intro'ing it *)
      (destruct (width =? 32) eqn: E'; [apply Z.eqb_eq in E' | apply Z.eqb_neq in E']);
      try congruence;
      clear E';
      [set (nBytes := 4%nat) | set (nBytes := 8%nat)];
      replace (Z.to_nat ((width + 7) / 8)) with nBytes by (subst nBytes; rewrite E; reflexivity);
      subst nBytes;
      intros; destruct sz; try solve [
        unfold execute, ExecuteI.execute, ExecuteI64.execute, translate, DefaultRiscvState,
        Memory.store, Memory.store_Z in *;
        simp; simulate''; simpl; simpl_word_exprs word_ok; eassumption].
  Qed.

  Definition runsTo: RiscvMachineL -> (RiscvMachineL -> Prop) -> Prop :=
    runsTo (mcomp_sat (run1 iset)).

  Lemma one_step: forall initialL P,
      mcomp_sat (run1 iset) initialL P ->
      runsTo initialL P.
  Proof.
    intros.
    eapply runsToStep; [eassumption|].
    intros.
    apply runsToDone. assumption.
  Qed.

  Ltac simpl_run1 :=
    cbv [run1 (*execState*) OStateNDOperations.put OStateNDOperations.get
         Return Bind State_Monad OStateND_Monad
         execute ExecuteI.execute ExecuteM.execute ExecuteI64.execute ExecuteM64.execute
         getRegs getPc getNextPc getMem getLog
         getPC setPC getRegister setRegister].

  Tactic Notation "log_solved" tactic(t) :=
    match goal with
    | |- ?G => let H := fresh in assert G as H by t; idtac "solved" G; exact H
    | |- ?G => idtac "did not solve" G
    end.

  Local Ltac solve_stmt_not_too_big :=
    lazymatch goal with
    | H: stmt_not_too_big _ |- stmt_not_too_big _ =>
        clear -H;
        unfold stmt_not_too_big in *;
        change (2 ^ 9)%Z with 512%Z in *;
        simpl stmt_size in H;
        repeat match goal with
               | s: stmt |- _ => unique pose proof (stmt_size_nonneg s)
               end;
        match goal with
        | |- ?SZ _ _ < _ => (* COQBUG https://github.com/coq/coq/issues/9268 *)
          change @stmt_size with SZ in *
        end;
        lia
    end.

  (* Needed because simpl will unfold (4 * ...) which is unreadable *)
  Local Ltac simpl_pow2 := idtac. (*
    repeat match goal with
    | |- context [1 + ?a] => change (1 + a) with (S a)
    | |- context [pow2 (S ?a)] => change (pow2 (S a)) with (2 * pow2 a)
    | |- context [pow2 0] => change (pow2 0) with 1
    end.
*)

  Ltac simpl_RiscvMachine_get_set := simpl in *. (* TODO is this enough? *)

  Ltac destruct_RiscvMachine_0 m :=
    let t := type of m in
    unify t RiscvMachine;
    let r := fresh m "_regs" in
    let p := fresh m "_pc" in
    let n := fresh m "_npc" in
    let e := fresh m "_eh" in
    let me := fresh m "_mem" in
    destruct m as [ [r p n e] me ];
    simpl_RiscvMachine_get_set.

  Ltac destruct_RiscvMachine m :=
    let t := type of m in
    unify t RiscvMachineL;
    let r := fresh m "_regs" in
    let p := fresh m "_pc" in
    let n := fresh m "_npc" in
    let me := fresh m "_mem" in
    let l := fresh m "_log" in
    destruct m as [r p n me l];
    simpl_RiscvMachine_get_set.

  Arguments Z.modulo : simpl never.

  Ltac solve_valid_registers :=
    match goal with
    | |- valid_registers _ => solve [simpl; auto]
    end.

  Instance word_eq_dec: DecidableEq word. (* TODO *) Admitted.

  Lemma disjoint_putmany_preserves_store_bytes: forall n a vs (m1 m1' mq: mem),
      store_bytes n m1 a vs = Some m1' ->
      map.disjoint m1 mq ->
      store_bytes n (map.putmany m1 mq) a vs = Some (map.putmany m1' mq).
  Proof.
    intros.
    unfold store_bytes, load_bytes, unchecked_store_bytes in *. simp.
    erewrite map.getmany_of_tuple_in_disjoint_putmany by eassumption.
    f_equal.
    set (ks := (footprint a n)) in *.
    rename mq into m2.
    rewrite map.putmany_of_tuple_to_putmany.
    rewrite (map.putmany_of_tuple_to_putmany n m1 ks vs).
    apply map.disjoint_putmany_commutes.
    pose proof map.getmany_of_tuple_to_sub_domain as P.
    specialize P with (1 := E).
    apply map.sub_domain_value_indep with (vs2 := vs) in P.
    set (mp := (map.putmany_of_tuple ks vs map.empty)) in *.
    apply map.disjoint_comm.
    eapply map.sub_domain_disjoint; eassumption.
  Qed.

  Lemma store_bytes_preserves_footprint: forall n a v (m m': mem),
      Memory.store_bytes n m a v = Some m' ->
      map.same_domain m m'.
  Proof.
    intros. unfold store_bytes, load_bytes, unchecked_store_bytes in *. simp.
    eauto using map.putmany_of_tuple_preserves_domain.
  Qed.

  Ltac simpl_bools :=
    repeat match goal with
           | H : ?x = false |- _ =>
             progress rewrite H in *
           | H : ?x = true |- _ =>
             progress rewrite H in *
           | |- context [negb true] => progress unfold negb
           | |- context [negb false] => progress unfold negb
           | H : negb ?x = true |- _ =>
             let H' := fresh in
             assert (x = false) as H' by (eapply negb_true_iff; eauto);
             clear H
           | H : negb ?x = false |- _ =>
             let H' := fresh in
             assert (x = true) as H' by (eapply negb_false_iff; eauto);
             clear H
           end.

  Ltac prove_ext_guarantee :=
    eapply ext_guarantee_preservable; [eassumption | simpl | reflexivity ];
    (* eauto using the lemmas below doesn't work, why? *)
    first [ eapply map.same_domain_refl |
            eapply store_bytes_preserves_footprint; eassumption ].

  Ltac simulate'_step :=
    first (* lemmas introduced only in this file: *)
          [ eapply go_load  ; [sidecondition..|]
          | eapply go_store ; [sidecondition..|]
          | simulate_step
          | simpl_modu4_0 ].

  Ltac simulate' := repeat simulate'_step.

  Ltac run1det :=
    eapply runsTo_det_step;
    [ simulate';
      match goal with
      | |- ?mid = ?RHS =>
        (* simpl RHS because mid will be instantiated to it and turn up again in the next step *)
        is_evar mid; simpl; reflexivity
      | |- _ => fail 10000 "simulate' did not go through completely"
      end
    | ].

  (* seplog which knows that "program" is an array and how to deal with cons and append in
     that array, and how to make addresses match *)
  Ltac pseplog :=
    unfold program in *;
    repeat match goal with
           | H: _ ?m |- _ ?m => progress (simpl in * (* does array_cons *))
           | H: context [array _ _ ?addr1 ?content] |- context [array _ _ ?addr2 ?content] =>
             progress replace addr1 with addr2 in H by ring;
               ring_simplify addr2;
               ring_simplify addr2 in H
           (* just unprotected seprewrite will instantiate evars in undesired ways *)
           | |- context [ array ?PT ?SZ ?start (?xs ++ ?ys) ] =>
             seprewrite0 (array_append_DEPRECATED PT SZ xs ys start)
           | H: context [ array ?PT ?SZ ?start (?xs ++ ?ys) ] |- _ =>
             seprewrite0_in (array_append_DEPRECATED PT SZ xs ys start) H
           end;
    seplog.

  Ltac apply_post :=
    match goal with
    | H: ?post _ _ _ |- ?post _ _ _ =>
      eqexact H; f_equal; symmetry;
      (apply word.sru_ignores_hibits ||
       apply word.slu_ignores_hibits ||
       apply word.srs_ignores_hibits ||
       apply word.mulhuu_simpl ||
       apply word.divu0_simpl ||
       apply word.modu0_simpl)
    end.

  Ltac run1done :=
    apply runsToDone;
    simpl in *;
    eexists;
    repeat split;
    simpl_word_exprs (@word_ok (@W (@def_params p)));
    first
      [ solve [eauto]
      | solve_word_eq (@word_ok (@W (@def_params p)))
      | solve [pseplog]
      | prove_ext_guarantee
      | apply_post
      | idtac ].

(*
  Ltac IH_done IH :=
    eapply runsToSatisfying_imp; [ exact IH | ];
    subst;
    clear;
    simpl;
    intros;
    destruct_products;
    repeat match goal with
           | |- _ /\ _ => split
           end;
    try assumption;
    try match goal with
        | H: ?m.(core).(pc) = _ |- ?m.(core).(pc) = _ => rewrite H
        end;
    solve_word_eq.
*)

  Arguments LittleEndian.combine: simpl never.

  Lemma iset_is_supported: supported_iset iset.
  Proof.
    unfold iset. destruct_one_match; constructor.
  Qed.

  Ltac substs :=
    repeat match goal with
           | x := _ |- _ => subst x
           | _: ?x = _ |- _ => subst x
           | _: _ = ?x |- _ => subst x
           end.

  Lemma compile_lit_large_correct: forall initialL post x v R d,
      initialL.(getNextPc) = add initialL.(getPc) (word.of_Z 4) ->
      d = mul (word.of_Z 4) (word.of_Z (Zlength (compile_lit_large x v))) ->
      (program initialL.(getPc) (compile_lit_large x v) * R)%sep initialL.(getMem) ->
      valid_registers (SLit x v) ->
      runsTo (withRegs   (map.put initialL.(getRegs) x (word.of_Z v))
             (withPc     (add initialL.(getPc) d)
             (withNextPc (add initialL.(getNextPc) d)
                         initialL)))
             post ->
      runsTo initialL post.
  Proof.
    unfold compile_lit_large, compile_lit_64bit, compile_lit_32bit in *.
    destruct width_cases as [E | E];
      (destruct (width =? 32) eqn: E'; pose proof E' as E'';
       [apply Z.eqb_eq in E'' | apply Z.eqb_neq in E'']);
      try congruence;
      clear E'';
      intros *; intros E1 Hd P V N; subst d;
      pose proof (compile_lit_large_emits_valid x v iset ltac:(auto)) as EV.
    - unfold compile_lit_large, compile_lit_32bit in *.
      rewrite E' in EV.
      destruct_RiscvMachine initialL. subst.
      simpl in *.
      run1det. run1det.
      match goal with
      | R: runsTo ?m post |- runsToNonDet.runsTo _ ?m' post =>
        replace m' with m; [exact R|]
      end.
      cbv [withRegs withPc withNextPc withMem withLog]. clear N. f_equal.
      + rewrite put_put_same. f_equal.
        apply word.signed_inj.
        rewrite word.signed_of_Z.
        rewrite word.signed_xor.
        rewrite! word.signed_of_Z.
        replace word.swrap with (signExtend_bitwise 32) by case TODO.
        rewrite! signExtend_alt_bitwise by reflexivity.
        clear.
        unfold signExtend_bitwise.
        Zbitwise.
      + solve_word_eq word_ok.
      + solve_word_eq word_ok.
    - unfold compile_lit_large, compile_lit_64bit, compile_lit_32bit in *.
      rewrite E' in EV.
      match type of EV with
      | context [ Addi _ _ ?a ] => remember a as mid
      end.
      (*
      match type of EV with
      | context [ ?a - mid ] => remember a as hi
      end.
      cbv [List.app program array] in P.
      simpl in *. (* if you don't remember enough values, this might take forever *)
      destruct initialL; simpl in *. subst getNextPc.
      autorewrite with rew_Zlength in N.
      simpl in N.
      run1det.
      run1det.
      run1det.
      run1det.
      run1det.
      run1det.
      run1det.
      run1det.
      match goal with
      | R: runsTo ?m post |- runsToNonDet.runsTo _ ?m' post =>
        replace m' with m; [exact R|]
      end.
      cbv [withRegs withPc withNextPc withMem withLog]. clear N P EV. f_equal.
      + rewrite! put_put_same. f_equal. subst. change (BinInt.Z.pow_pos 2 64) with (2 ^ 64).
        apply word.unsigned_inj.
        rewrite word.unsigned_of_Z. replace (2 ^ width) with (2 ^ 64) by congruence.
        apply compile_lit_64bit_correct. assumption.
      + solve_word_eq word_ok.
      + solve_word_eq word_ok.
  Qed.*) Admitted.

  Lemma compile_lit_correct_full: forall initialL post x v R,
      initialL.(getNextPc) = add initialL.(getPc) (ZToReg 4) ->
      let insts := compile_stmt (SLit x v) in
      let d := mul (ZToReg 4) (ZToReg (Zlength insts)) in
      (program initialL.(getPc) insts * R)%sep initialL.(getMem) ->
      valid_registers (SLit x v) ->
      runsTo (withRegs   (map.put initialL.(getRegs) x (ZToReg v))
             (withPc     (add initialL.(getPc) d)
             (withNextPc (add initialL.(getNextPc) d)
                         initialL)))
             post ->
      runsTo initialL post.
  Proof.
    intros *. intros E1 insts d P V N. substs.
    lazymatch goal with
    | H1: valid_registers ?s |- _ =>
      pose proof (compile_stmt_emits_valid iset_is_supported H1 eq_refl) as EV
    end.
    simpl in *.
    destruct_RiscvMachine initialL.
    subst.
    unfold compile_lit_new in *.
    destruct (dec (- 2 ^ 11 <= v < 2 ^ 11)). {
      unfold compile_lit_12bit in *.
      run1det.
      simpl_word_exprs word_ok.
      exact N.
    }
    eapply compile_lit_large_correct; sidecondition.
  Qed.

  Definition eval_stmt := exec map.empty.

  Lemma seplog_subst_eq{A B R: mem -> Prop} {mL mH: mem}
      (H: A mL)
      (H0: iff1 A (R * eq mH)%sep)
      (H1: B mH):
      (B * R)%sep mL.
  Proof.
    unfold iff1 in *.
    destruct (H0 mL) as [P1 P2]. specialize (P1 H).
    apply sep_comm.
    unfold sep in *.
    destruct P1 as (mR & mH' & P11 & P12 & P13). subst mH'. eauto.
  Qed.

  Lemma subst_load_bytes_for_eq {sz} {mH mL: mem} {addr: word} {bs P R}:
      let n := @Memory.bytes_per width sz in
      bedrock2.Memory.load_bytes n mH addr = Some bs ->
      (P * eq mH * R)%sep mL ->
      exists Q, (P * ptsto_bytes n addr bs * Q * R)%sep mL.
  Proof.
    intros n H H0.
    apply sep_of_load_bytes in H; cycle 1. {
      subst n. clear. destruct sz; destruct width_cases as [C | C]; rewrite C; cbv; discriminate.
    }
    destruct H as [Q A]. exists Q.
    assert (((ptsto_bytes n addr bs * Q) * (P * R))%sep mL); [|ecancel_assumption].
    eapply seplog_subst_eq; [exact H0|..|exact A]. ecancel.
  Qed.

  Ltac subst_load_bytes_for_eq :=
    match goal with
    | Load: bedrock2.Memory.load_bytes _ ?m _ = _, Sep: (_ * eq ?m * _)%sep _ |- _ =>
      let Q := fresh "Q" in
      destruct (subst_load_bytes_for_eq Load Sep) as [Q ?]
    end.

  Lemma store_bytes_frame: forall {n: nat} {m1 m1' m: mem} {a: word} {v: HList.tuple byte n} {F},
      Memory.store_bytes n m1 a v = Some m1' ->
      (eq m1 * F)%sep m ->
      exists m', (eq m1' * F)%sep m' /\ Memory.store_bytes n m a v = Some m'.
  Proof.
    intros.
    unfold sep in H0.
    destruct H0 as (mp & mq & A & B & C).
    subst mp.
    unfold map.split in A. destruct A as [A1 A2].
    eexists (map.putmany m1' mq).
    split.
    - unfold sep.
      exists m1' mq. repeat split; trivial.
      apply store_bytes_preserves_footprint in H.
      clear -H A2.
      unfold map.disjoint, map.same_domain, map.sub_domain in *. destruct H as [P Q].
      intros.
      edestruct Q; eauto.
    - subst m.
      eauto using disjoint_putmany_preserves_store_bytes.
  Qed.

  Ltac IH_sidecondition :=
    simpl_word_exprs (@word_ok (@W (@def_params p)));
    first
      [ reflexivity
      | solve [auto]
      | solve_stmt_not_too_big
      | solve_word_eq (@word_ok (@W (@def_params p)))
      | solve_divisibleBy4
      | prove_ext_guarantee
      | pseplog
      | idtac ].

  Arguments map.empty: simpl never.
  Arguments map.get: simpl never.

  Lemma compile_stmt_correct:
    forall (s: stmt) t initialMH initialRegsH postH,
    eval_stmt s t initialMH initialRegsH postH ->
    forall R initialL insts,
    @compile_stmt def_params s = insts ->
    stmt_not_too_big s ->
    valid_registers s ->
    divisibleBy4 initialL.(getPc) ->
    initialL.(getRegs) = initialRegsH ->
    (program initialL.(getPc) insts * eq initialMH * R)%sep initialL.(getMem) ->
    initialL.(getLog) = t ->
    initialL.(getNextPc) = add initialL.(getPc) (ZToReg 4) ->
    ext_guarantee initialL ->
    runsTo initialL (fun finalL => exists finalMH,
          postH finalL.(getLog) finalMH finalL.(getRegs) /\
          (program initialL.(getPc) insts * eq finalMH * R)%sep finalL.(getMem) /\
          finalL.(getPc) = add initialL.(getPc) (mul (ZToReg 4) (ZToReg (Zlength insts))) /\
          finalL.(getNextPc) = add finalL.(getPc) (ZToReg 4) /\
          ext_guarantee finalL).
  Proof.
    pose proof compile_stmt_emits_valid.
    induction 1; intros;
      lazymatch goal with
      | H1: valid_registers ?s, H2: stmt_not_too_big ?s |- _ =>
        pose proof (compile_stmt_emits_valid iset_is_supported H1 H2)
      end;
      repeat match goal with
             | m: _ |- _ => destruct_RiscvMachine m
             end;
      simpl in *;
      subst;
      simp.

    - (* SInteract *)
      eapply runsTo_weaken.
      + eapply compile_ext_call_correct with (postH := post) (action0 := action)
                                             (argvars0 := argvars) (resvars0 := resvars);
          simpl; reflexivity || eassumption || ecancel_assumption || idtac.
        eapply @exec.interact; try eassumption.
      + simpl. intros finalL A. destruct_RiscvMachine finalL. simpl in *.
        destruct_products. subst. eauto 7.

    - (* SCall *)
      match goal with
      | A: map.get map.empty _ = Some _ |- _ =>
        clear -A; exfalso; simpl in *;
        rewrite map.get_empty in A
      end.
      discriminate.

    - (* SLoad *)
      unfold Memory.load, Memory.load_Z in *. simp. subst_load_bytes_for_eq.
      run1det. run1done.

    - (* SStore *)
      assert ((eq m * (program initialL_pc [[compile_store sz a v 0]] * R))%sep initialL_mem)
             as A by ecancel_assumption.
      pose proof (store_bytes_frame H2 A) as P.
      destruct P as (finalML & P1 & P2).
      run1det. run1done.

    - (* SLit *)
      eapply compile_lit_correct_full.
      + sidecondition.
      + unfold compile_stmt. unfold getPc, getMem. ecancel_assumption.
      + sidecondition.
      + simpl. run1done.

      (* SOp *)
    - match goal with
      | o: Syntax.bopname.bopname |- _ => destruct o
      end;
      simpl in *; run1det; try solve [run1done].
      run1det. run1done.
      match goal with
      | H: ?post _ _ _ |- ?post _ _ _ => eqexact H
      end.
      rewrite reduce_eq_to_sub_and_lt.
      symmetry. apply put_put_same.

    - (* SSet *)
      run1det. run1done.

    - (* SIf/Then *)
      (* execute branch instruction, which will not jump *)
      eapply runsTo_det_step; simpl in *; subst.
      + simulate'.
        destruct cond; [destruct op | ];
          simpl in *; simp; repeat (simulate'; simpl_bools; simpl); try reflexivity.
      + eapply runsTo_trans.
        * (* use IH for then-branch *)
          eapply IHexec; IH_sidecondition.
        * (* jump over else-branch *)
          simpl. intros. simp. destruct_RiscvMachine middle. subst.
          run1det. run1done.

    - (* SIf/Else *)
      (* execute branch instruction, which will jump over then-branch *)
      eapply runsTo_det_step; simpl in *; subst.
      + simulate'.
        destruct cond; [destruct op | ];
          simpl in *; simp; repeat (simulate'; simpl_bools; simpl); try reflexivity.
      + eapply runsTo_trans.
        * (* use IH for else-branch *)
          eapply IHexec; IH_sidecondition.
        * (* at end of else-branch, i.e. also at end of if-then-else, just prove that
             computed post satisfies required post *)
          simpl. intros. simp. destruct_RiscvMachine middle. subst. run1done.

    - (* SLoop/again *)
      on hyp[(stmt_not_too_big body1); runsTo] do (fun H => rename H into IH1).
      on hyp[(stmt_not_too_big body2); runsTo] do (fun H => rename H into IH2).
      on hyp[(stmt_not_too_big (SLoop body1 cond body2)); runsTo] do (fun H => rename H into IH12).
      eapply runsTo_trans.
      + (* 1st application of IH: part 1 of loop body *)
        eapply IH1; IH_sidecondition.
      + simpl in *. simpl. intros. simp. destruct_RiscvMachine middle. subst.
        destruct (@eval_bcond (@Semantics_params p) middle_regs cond) as [condB|] eqn: E.
        2: exfalso;
           match goal with
           | H: context [_ <> None] |- _ => solve [eapply H; eauto]
           end.
        destruct condB.
        * (* true: iterate again *)
          eapply runsTo_det_step; simpl in *; subst.
          { simulate'.
            destruct cond; [destruct op | ];
              simpl in *; simp; repeat (simulate'; simpl_bools; simpl); try reflexivity. }
          { eapply runsTo_trans.
            - (* 2nd application of IH: part 2 of loop body *)
              eapply IH2; IH_sidecondition.
            - simpl in *. simpl. intros. simp. destruct_RiscvMachine middle. subst.
              (* jump back to beginning of loop: *)
              run1det.
              eapply runsTo_trans.
              + (* 3rd application of IH: run the whole loop again *)
                eapply IH12; IH_sidecondition.
              + (* at end of loop, just prove that computed post satisfies required post *)
                simpl. intros. simp. destruct_RiscvMachine middle. subst.
                run1done. }
        * (* false: done, jump over body2 *)
          eapply runsTo_det_step; simpl in *; subst.
          { simulate'.
            destruct cond; [destruct op | ];
              simpl in *; simp; repeat (simulate'; simpl_bools; simpl); try reflexivity. }
          { simpl in *. run1done. }

    - (* SSeq *)
      rename IHexec into IH1, H2 into IH2.
      eapply runsTo_trans.
      + eapply IH1; IH_sidecondition.
      + simpl. intros. simp. destruct_RiscvMachine middle. subst.
        eapply runsTo_trans.
        * eapply IH2; IH_sidecondition.
        * simpl. intros. simp. destruct_RiscvMachine middle. subst. run1done.

    - (* SSkip *)
      run1done.
  Qed.

End FlatToRiscv1.
