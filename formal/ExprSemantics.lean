/-
  ExprSemantics: Language-Agnostic Expression Semantics for Cell Computation

  Formalizes the Pure tier of the cell expression language — the
  denotational model is independent of surface syntax (Lua, S-expressions,
  or any future substrate). The abstract Expr AST represents the common
  structure: symbols, literals, compound expressions.

  Key results:
  1. Expr — abstract expression AST (language-agnostic)
  2. ZVal — extended value domain (strings, ints, bools, lists, hashes, programs)
  3. Built-in function effect classification (Pure/Replayable/NonReplayable)
  4. Static checkEffects: walk AST, verify all symbols ≤ tier
  5. Big-step eval with effect tracking
  6. effect_safety theorem: checkEffects(ast, tier) = true →
     eval produces no effects above tier (PROVEN, zero sorries)

  The abstract model maps to concrete substrates:
  - Lua (current): static scan for restricted globals + setfenv sandbox
  - S-expressions (previous): AST walk over homoiconic structure
  The formal guarantees hold for any substrate that correctly maps to
  the abstract Expr representation.

  Imports Core.lean for identity types and Autopour.lean for EffLevel.

  History:
  - ZygoSemantics.lean (Glassblower, 2026-03-21, dc-rgt) — original
  - Effect bugs fixed + ZygoExpr reconciliation (Glassblower, 2026-03-21, dc-wkw)
  - effect_safety proved (Sussmind, 2026-03-21)
  - Generalized to ExprSemantics (Glassblower, 2026-03-21) — Lua substrate change
-/

import Core
import Autopour

namespace ExprSemantics

open Autopour (EffLevel)

/-! ====================================================================
    ABSTRACT EXPRESSION AST
    ==================================================================== -/

/-- Abstract expression AST for cell computation.
    Language-agnostic: represents the common structure of any expression
    language (Lua, S-expressions, etc.) at the level needed for effect
    checking and denotational semantics. -/
inductive SExpr where
  | sym   : String → SExpr              -- symbol (function name, variable)
  | str   : String → SExpr              -- string literal
  | num   : Int → SExpr                 -- numeric literal
  | slist : List SExpr → SExpr          -- compound expression (function call)
  deriving Repr

/-! ====================================================================
    EXTENDED VALUE DOMAIN
    ==================================================================== -/

/-- Values produced by expression evaluation. Extends Autopour.Val with
    structured data needed for computation tiers. -/
inductive ZVal where
  | str     : String → ZVal
  | num     : Int → ZVal
  | bool    : Bool → ZVal               -- truthiness support
  | vlist   : List ZVal → ZVal
  | hash    : List (String × ZVal) → ZVal  -- key-value maps
  | none    : ZVal
  | error   : String → ZVal
  | program : SExpr → ZVal              -- a program is a value (homoiconicity)
  deriving Repr

def ZVal.isError : ZVal → Bool
  | .error _ => true
  | _ => false

/-- Truthiness: nil, false, and error are falsy; everything else is truthy.
    Used by conditionals. -/
def ZVal.truthy : ZVal → Bool
  | .none     => false
  | .bool b   => b
  | .error _  => false
  | _         => true

/-- Coerce a ZVal to a string for yield output. -/
def ZVal.toStr : ZVal → String
  | .str s    => s
  | .num n    => toString n
  | .bool b   => toString b
  | .none     => "nil"
  | .vlist _  => "<list>"
  | .hash _   => "<hash>"
  | .error e  => s!"error: {e}"
  | .program _ => "<program>"

/-- Bridge: convert ZVal to cell-level Val (Autopour.Val).
    Yields are strings in the tuple space; structured data serializes. -/
def ZVal.toCellVal : ZVal → Autopour.Val
  | .str s     => .str s
  | .num n     => .str (toString n)
  | .bool b    => .str (toString b)
  | .vlist _   => .str "<list>"
  | .hash _    => .str "<hash>"
  | .none      => .none
  | .error e   => .error e
  | .program _ => .str "<program>"

/-! ====================================================================
    ENVIRONMENT
    ==================================================================== -/

abbrev ZEnv := List (String × ZVal)

def ZEnv.lookup (env : ZEnv) (name : String) : ZVal :=
  match env.find? (fun p => p.1 == name) with
  | some (_, v) => v
  | none => .none

def ZEnv.bind (env : ZEnv) (name : String) (v : ZVal) : ZEnv :=
  (name, v) :: env

/-! ====================================================================
    BUILT-IN FUNCTION EFFECT CLASSIFICATION
    ==================================================================== -/

/-- Built-in functions recognized by the evaluator.
    Each has a known effect level. Unknown symbols are conservative
    (classified at the caller's declared level). -/
inductive Builtin where
  -- Pure (arithmetic)
  | add | sub | mul | div | modulo
  -- Pure (string)
  | concat | strlen | substr
  -- Pure (list)
  | cons | car | cdr | listCtor | len
  -- Pure (control)
  | ifExpr | let_ | eq | lt | gt
  -- Pure (quoting — reification only, NOT reflection)
  | quote
  -- Replayable (LLM + read-only tuple space)
  | llmCall | llmJudge | observe
  -- NonReplayable (tuple space mutation + reflection)
  | pour | claim | submit | readString
  -- NonReplayable (external)
  | httpGet | httpPost | sqlExec
  deriving Repr, DecidableEq, BEq

/-- Classify a built-in's effect level. -/
def Builtin.effLevel : Builtin → EffLevel
  | .add | .sub | .mul | .div | .modulo => .pure
  | .concat | .strlen | .substr         => .pure
  | .cons | .car | .cdr | .listCtor | .len => .pure
  | .ifExpr | .let_ | .eq | .lt | .gt   => .pure
  | .quote                               => .pure
  | .llmCall | .llmJudge | .observe     => .replayable
  | .pour | .claim | .submit | .readString => .nonReplayable
  | .httpGet | .httpPost | .sqlExec     => .nonReplayable

/-- Resolve a symbol name to a Builtin (if known). -/
def resolveBuiltin : String → Option Builtin
  | "+"           => some .add
  | "-"           => some .sub
  | "*"           => some .mul
  | "/"           => some .div
  | "mod"         => some .modulo
  | "concat"      => some .concat
  | "strlen"      => some .strlen
  | "substr"      => some .substr
  | "cons"        => some .cons
  | "car"         => some .car
  | "cdr"         => some .cdr
  | "list"        => some .listCtor
  | "len"         => some .len
  | "if"          => some .ifExpr
  | "let"         => some .let_
  | "="           => some .eq
  | "<"           => some .lt
  | ">"           => some .gt
  | "quote"       => some .quote
  | "read-string" => some .readString
  | "llm-call"    => some .llmCall
  | "llm-judge"   => some .llmJudge
  | "pour"        => some .pour
  | "claim"       => some .claim
  | "submit"      => some .submit
  | "observe"     => some .observe
  | "http-get"    => some .httpGet
  | "http-post"   => some .httpPost
  | "sql-exec"    => some .sqlExec
  | _             => none

/-! ====================================================================
    STATIC EFFECT CHECKING
    ==================================================================== -/

/-- Check whether a symbol is allowed at a given effect tier.
    Known built-ins: check their level against the tier.
    Unknown symbols: conservatively allowed (variables or user-defined
    functions checked at their definition site). -/
def symbolAllowed (name : String) (tier : EffLevel) : Bool :=
  match resolveBuiltin name with
  | some b => EffLevel.le b.effLevel tier
  | none   => true

/-- EffLevel.le is transitive: if a ≤ b and b ≤ c then a ≤ c (Bool version). -/
private theorem effLevel_le_trans {a b c : EffLevel}
    (hab : EffLevel.le a b = true) (hbc : b ≤ c) :
    EffLevel.le a c = true := by
  simp [EffLevel.le] at *
  show a.toNat ≤ c.toNat
  exact Nat.le_trans hab (by exact hbc)

/-- symbolAllowed is monotone in tier: if allowed at t1 and t1 ≤ t2,
    then allowed at t2. -/
theorem symbolAllowed_mono (name : String) (t1 t2 : EffLevel) (h12 : t1 ≤ t2)
    (h : symbolAllowed name t1 = true) :
    symbolAllowed name t2 = true := by
  unfold symbolAllowed at *
  split
  · rename_i b hb
    rw [hb] at h
    exact effLevel_le_trans h h12
  · rfl

/-- Walk the AST and check that every function symbol is allowed at the tier.
    Uses fuel to ensure termination over the recursive SExpr structure. -/
def checkEffects (fuel : Nat) (expr : SExpr) (tier : EffLevel) : Bool :=
  match fuel with
  | 0 => false    -- fuel exhausted: conservatively reject
  | fuel' + 1 =>
    match expr with
    | .sym s   => symbolAllowed s tier
    | .str _   => true
    | .num _   => true
    | .slist [] => true
    | .slist (head :: args) =>
      checkEffects fuel' head tier &&
      args.all (fun arg => checkEffects fuel' arg tier)

/-! ====================================================================
    BIG-STEP EVALUATION (Pure Tier)
    ==================================================================== -/

/-- Result of evaluation: a value plus a (possibly empty) list of
    effect levels actually performed during evaluation. -/
structure EvalResult where
  val     : ZVal
  effects : List EffLevel
  deriving Repr

def EvalResult.pure (v : ZVal) : EvalResult :=
  { val := v, effects := [] }

def EvalResult.withEffect (v : ZVal) (e : EffLevel) : EvalResult :=
  { val := v, effects := [e] }

/-- Join two effect levels (max). Local copy — avoids importing EffectEval. -/
def effJoin (a b : EffLevel) : EffLevel :=
  if b.toNat ≤ a.toNat then a else b

/-- Maximum effect level in a list (pure if empty). -/
def maxEffect : List EffLevel → EffLevel :=
  List.foldl effJoin .pure

/-- Merge effects from multiple results. -/
def mergeEffects (results : List EvalResult) : List EffLevel :=
  (results.map (·.effects)).flatten

/-- Big-step evaluation of abstract expressions.
    Fuel-bounded for termination in Lean.
    Tracks actual effects performed (for the safety theorem).

    Design: The eval function handles Pure built-ins inline (no effect
    tag). Effectful built-ins (Replayable, NonReplayable) produce a
    placeholder value and tag their effect level. This lets the safety
    theorem distinguish "actually pure evaluation" from "evaluation
    that performed effects."

    Language-agnostic: maps to Lua (loadstring+setfenv), S-expressions,
    or any substrate whose expressions can be represented as this AST. -/
def eval (fuel : Nat) (env : ZEnv) (expr : SExpr) : EvalResult :=
  match fuel with
  | 0 => EvalResult.pure (.error "fuel exhausted")
  | fuel' + 1 =>
    match expr with
    | .str s => EvalResult.pure (.str s)
    | .num n => EvalResult.pure (.num n)
    | .sym name => EvalResult.pure (env.lookup name)
    | .slist [] => EvalResult.pure .none

    -- quote: return AST as program value
    | .slist [.sym "quote", arg] => EvalResult.pure (.program arg)

    -- if: conditional (uses truthy semantics)
    | .slist [.sym "if", cond, thenBr, elseBr] =>
      let cr := eval fuel' env cond
      match cr.val with
      | .error e => { val := .error e, effects := cr.effects }
      | v        => if v.truthy
                    then let tr := eval fuel' env thenBr
                         { val := tr.val, effects := cr.effects ++ tr.effects }
                    else let er := eval fuel' env elseBr
                         { val := er.val, effects := cr.effects ++ er.effects }

    -- let: variable binding
    | .slist [.sym "let", .sym name, valExpr, bodyExpr] =>
      let vr := eval fuel' env valExpr
      match vr.val with
      | .error e => { val := .error e, effects := vr.effects }
      | v        => let br := eval fuel' (env.bind name v) bodyExpr
                    { val := br.val, effects := vr.effects ++ br.effects }

    -- arithmetic: +, -, *
    | .slist [.sym "+", a, b] =>
      let ar := eval fuel' env a
      let br := eval fuel' env b
      match ar.val, br.val with
      | .num x, .num y => { val := .num (x + y), effects := ar.effects ++ br.effects }
      | _, _ => { val := .error "type error: + expects numbers",
                  effects := ar.effects ++ br.effects }

    | .slist [.sym "-", a, b] =>
      let ar := eval fuel' env a
      let br := eval fuel' env b
      match ar.val, br.val with
      | .num x, .num y => { val := .num (x - y), effects := ar.effects ++ br.effects }
      | _, _ => { val := .error "type error: - expects numbers",
                  effects := ar.effects ++ br.effects }

    | .slist [.sym "*", a, b] =>
      let ar := eval fuel' env a
      let br := eval fuel' env b
      match ar.val, br.val with
      | .num x, .num y => { val := .num (x * y), effects := ar.effects ++ br.effects }
      | _, _ => { val := .error "type error: * expects numbers",
                  effects := ar.effects ++ br.effects }

    -- equality
    | .slist [.sym "=", a, b] =>
      let ar := eval fuel' env a
      let br := eval fuel' env b
      -- Structural equality via pattern matching (BEq not available for ZVal)
      let eq := match ar.val, br.val with
        | .num x, .num y     => x == y
        | .str x, .str y     => x == y
        | .bool x, .bool y   => x == y
        | .none, .none       => true
        | _, _               => false
      { val := if eq then .bool true else .bool false,
        effects := ar.effects ++ br.effects }

    -- string operations
    | .slist [.sym "concat", a, b] =>
      let ar := eval fuel' env a
      let br := eval fuel' env b
      match ar.val, br.val with
      | .str x, .str y => { val := .str (x ++ y), effects := ar.effects ++ br.effects }
      | _, _ => { val := .error "type error: concat expects strings",
                  effects := ar.effects ++ br.effects }

    | .slist [.sym "strlen", a] =>
      let ar := eval fuel' env a
      match ar.val with
      | .str s => { val := .num s.length, effects := ar.effects }
      | _ => { val := .error "type error: strlen expects string", effects := ar.effects }

    -- list operations
    | .slist (.sym "list" :: args) =>
      let results := args.map (eval fuel' env)
      let vals := results.map (·.val)
      { val := .vlist vals, effects := mergeEffects results }

    | .slist [.sym "cons", h, t] =>
      let hr := eval fuel' env h
      let tr := eval fuel' env t
      match tr.val with
      | .vlist xs => { val := .vlist (hr.val :: xs), effects := hr.effects ++ tr.effects }
      | _ => { val := .error "type error: cons expects list tail",
               effects := hr.effects ++ tr.effects }

    | .slist [.sym "car", l] =>
      let lr := eval fuel' env l
      match lr.val with
      | .vlist (x :: _) => { val := x, effects := lr.effects }
      | .vlist []       => { val := .none, effects := lr.effects }
      | _ => { val := .error "type error: car expects list", effects := lr.effects }

    | .slist [.sym "cdr", l] =>
      let lr := eval fuel' env l
      match lr.val with
      | .vlist (_ :: xs) => { val := .vlist xs, effects := lr.effects }
      | .vlist []        => { val := .vlist [], effects := lr.effects }
      | _ => { val := .error "type error: cdr expects list", effects := lr.effects }

    | .slist [.sym "len", l] =>
      let lr := eval fuel' env l
      match lr.val with
      | .vlist xs => { val := .num xs.length, effects := lr.effects }
      | .str s    => { val := .num s.length, effects := lr.effects }
      | _ => { val := .error "type error: len expects list or string", effects := lr.effects }

    -- Generic function call: evaluate args, tag effect from built-in
    | .slist (.sym fname :: args) =>
      let results := args.map (eval fuel' env)
      let effs := mergeEffects results
      match resolveBuiltin fname with
      | some b => { val := .str s!"<{fname} result>",
                    effects := effs ++ [b.effLevel] }
      | none   => { val := .error s!"unknown function: {fname}", effects := effs }

    | .slist _ => EvalResult.pure (.error "invalid expression: non-symbol head")

/-! ====================================================================
    EFFECT SAFETY THEOREM
    ==================================================================== -/

/-- An EvalResult respects a tier if all its actual effects are ≤ tier. -/
def EvalResult.respectsTier (r : EvalResult) (tier : EffLevel) : Prop :=
  ∀ e ∈ r.effects, e ≤ tier

/-! ====================================================================
    HELPER LEMMAS FOR EFFECT SAFETY
    ==================================================================== -/

/-- If all effects in two lists respect a tier, so does their append. -/
private theorem respectsTier_append {l1 l2 : List EffLevel} {tier : EffLevel}
    (h1 : ∀ e ∈ l1, e ≤ tier) (h2 : ∀ e ∈ l2, e ≤ tier) :
    ∀ e ∈ l1 ++ l2, e ≤ tier := by
  intro e he
  rw [List.mem_append] at he
  cases he with
  | inl h => exact h1 e h
  | inr h => exact h2 e h

/-- If symbolAllowed returns true and the symbol resolves to a builtin,
    then the builtin's effect level ≤ tier. -/
private theorem symbolAllowed_builtin_le {fname : String} {tier : EffLevel} {b : Builtin}
    (hAllowed : symbolAllowed fname tier = true)
    (hResolve : resolveBuiltin fname = some b) :
    b.effLevel ≤ tier := by
  simp [symbolAllowed, hResolve, EffLevel.le] at hAllowed
  exact hAllowed

/-- mergeEffects respects tier if every result in the list does. -/
private theorem respectsTier_mergeEffects {results : List EvalResult} {tier : EffLevel}
    (h : ∀ r ∈ results, ∀ e ∈ r.effects, e ≤ tier) :
    ∀ e ∈ mergeEffects results, e ≤ tier := by
  intro e he
  simp [mergeEffects] at he
  obtain ⟨effs, ⟨r, hr, rfl⟩, he⟩ := he
  exact h r hr e he

/-- Singleton list membership: e ∈ [x] implies e = x. -/
private theorem mem_singleton {α : Type} {e x : α} (h : e ∈ [x]) : e = x := by
  simp [List.mem_cons] at h
  exact h

/-- Bool version for decidable checking. -/
def EvalResult.respectsTierB (r : EvalResult) (tier : EffLevel) : Bool :=
  r.effects.all (fun e => EffLevel.le e tier)

/-- EffLevel.le = true implies LE. -/
private theorem effLevel_le_of_bool {a b : EffLevel}
    (h : EffLevel.le a b = true) : a ≤ b := by
  simp [EffLevel.le] at h
  show a.toNat ≤ b.toNat
  exact h

/-- The Bool check implies the Prop. -/
theorem respectsTier_of_B (r : EvalResult) (tier : EffLevel)
    (h : r.respectsTierB tier = true) :
    r.respectsTier tier := by
  intro e he
  simp [EvalResult.respectsTierB, List.all_eq_true] at h
  exact effLevel_le_of_bool (h e he)

/-- Pure evaluation result produces no effects. -/
theorem pure_result_respects_all (v : ZVal) (tier : EffLevel) :
    (EvalResult.pure v).respectsTier tier := by
  intro e he
  simp [EvalResult.pure] at he

/-- Helper: effects from mapping eval over args respect tier if all args pass checkEffects. -/
private theorem eval_map_respectsTier (n : Nat) (env : ZEnv) (args : List SExpr) (tier : EffLevel)
    (ih : ∀ (env' : ZEnv) (expr : SExpr), checkEffects n expr tier = true →
      (eval n env' expr).respectsTier tier)
    (hArgs : ∀ a ∈ args, checkEffects n a tier = true) :
    ∀ e ∈ mergeEffects (args.map (eval n env)), e ≤ tier := by
  intro e he
  simp [mergeEffects] at he
  obtain ⟨effs, ⟨arg, harg, heval⟩, he⟩ := he
  rw [← heval] at he
  exact ih env arg (hArgs arg harg) e he

/-- KEY THEOREM: If checkEffects passes for a tier, then evaluating
    the expression produces only effects at or below that tier.

    This is the static effect checking soundness theorem from
    the substrate design (Section 9).

    The proof is by induction on fuel, then case analysis matching eval's
    pattern-match arms. Each arm either returns pure (empty effects) or
    combines sub-expression effects (covered by IH) with at most one
    builtin effect tag (covered by symbolAllowed). -/
theorem effect_safety (fuel : Nat) (env : ZEnv) (expr : SExpr) (tier : EffLevel)
    (hCheck : checkEffects fuel expr tier = true) :
    (eval fuel env expr).respectsTier tier := by
  induction fuel generalizing env expr with
  | zero => simp [checkEffects] at hCheck
  | succ n ih =>
    match expr with
    | .str _ => exact pure_result_respects_all _ tier
    | .num _ => exact pure_result_respects_all _ tier
    | .sym _ => exact pure_result_respects_all _ tier
    | .slist [] => exact pure_result_respects_all _ tier
    | .slist (head :: args) =>
      simp only [checkEffects, Bool.and_eq_true, List.all_eq_true] at hCheck
      obtain ⟨hHead, hArgs⟩ := hCheck
      -- Convenience: IH for any subexpression
      have ihSub : ∀ (env' : ZEnv) (e : SExpr),
          checkEffects n e tier = true → (eval n env' e).respectsTier tier :=
        fun env' e hc => ih env' e hc
      -- Non-symbol heads fall through to eval's last arm: pure error
      match head with
      | .str _ => exact pure_result_respects_all _ tier
      | .num _ => exact pure_result_respects_all _ tier
      | .slist _ => exact pure_result_respects_all _ tier
      | .sym fname =>
        have hSym : symbolAllowed fname tier = true := by
          match n with
          | 0 => simp [checkEffects] at hHead
          | m + 1 => simp [checkEffects] at hHead; exact hHead
        have ihArg : ∀ (a : SExpr), a ∈ args → ∀ env',
            (eval n env' a).respectsTier tier :=
          fun a ha env' => ihSub env' a (hArgs a ha)
        -- Proof strategy: unfold eval to expose the pattern match, then
        -- split into one subgoal per eval arm. Close each subgoal by:
        --   (1) pure_result_respects_all for empty-effect arms
        --   (2) contradiction on heq for impossible patterns
        --   (3) IH + membership for sub-eval effects
        --   (4) symbolAllowed_builtin_le for builtin effect tags
        --
        -- Helper: mergeEffects from eval-mapping respects tier (for list/generic)
        have hMerge : ∀ e ∈ mergeEffects (args.map (eval n env)), e ≤ tier := by
          intro e he; simp [mergeEffects] at he
          obtain ⟨effs, ⟨arg, harg, heval⟩, he⟩ := he
          rw [← heval] at he; exact ihSub env arg (hArgs arg harg) e he
        -- Helper: builtin effect ≤ tier when symbolAllowed
        have hBuiltin : ∀ b, resolveBuiltin fname = some b → b.effLevel ≤ tier := by
          intro b hb; simp [symbolAllowed, hb, EffLevel.le] at hSym; exact hSym
        -- Unfold eval and split on the match tree
        unfold eval; split
        -- Phase 1: close pure-result goals (catch-all arm of eval returns pure error)
        all_goals first
          | exact pure_result_respects_all _ _
          | skip
        -- Phase 2: simplify heq and substitute equalities
        all_goals
          (first | (rename_i heq; simp [SExpr.slist.injEq, SExpr.sym.injEq] at heq) | skip)
        all_goals (first
          | (rename_i heq; first
              | (obtain ⟨rfl, rfl⟩ := heq)
              | (obtain ⟨rfl, rfl, rfl⟩ := heq)
              | (subst heq))
          | (try subst_vars))
        -- Phase 3: close all remaining goals using IH, membership, and helpers
        -- Every remaining goal has effects composed from sub-expression evals
        -- (possibly under value-matches and if-then-else) plus at most one
        -- builtin effect tag.
        all_goals (
          intro e he
          -- Reduce let-bindings (have := ...) in the hypothesis
          try dsimp only [] at he
          first
          -- (A) Direct: e is in a single sub-eval's effects
          | exact ihArg _ (by simp [List.mem_cons]) env e he
          -- (B) Append: e ∈ a.effects ++ b.effects
          | (rw [List.mem_append] at he; rcases he with he | he
             · exact ihArg _ (by simp [List.mem_cons]) env e he
             · first
               | exact ihArg _ (by simp [List.mem_cons]) env e he
               -- let-binding: bodyExpr uses modified env, apply ihSub
               | exact ihSub _ _ (hArgs _ (by simp [List.mem_cons])) e he)
          -- (C) Effects under value-match (binary ops, cons, strlen, car, cdr, len)
          | (split at he <;> (
               first
               | exact ihArg _ (by simp [List.mem_cons]) env e he
               | (rw [List.mem_append] at he; rcases he with he | he
                  · exact ihArg _ (by simp [List.mem_cons]) env e he
                  · first
                    | exact ihArg _ (by simp [List.mem_cons]) env e he
                    | exact ihSub _ _ (hArgs _ (by simp [List.mem_cons])) e he)))
          -- (D) if: match on cr.val then if-then-else branching
          | (split at he
             · exact ihArg _ (by simp [List.mem_cons]) env e he
             · split at he <;> (
                 rw [List.mem_append] at he; rcases he with he | he
                 · exact ihArg _ (by simp [List.mem_cons]) env e he
                 · first
                   | exact ihArg _ (by simp [List.mem_cons]) env e he
                   | exact ihSub _ _ (hArgs _ (by simp [List.mem_cons])) e he))
          -- (E) mergeEffects only (list constructor)
          | exact hMerge e he
          -- (F) Generic fallthrough: mergeEffects ++ [b.effLevel]
          | (split at he
             · rename_i b hb; simp at he; rcases he with he | he
               · exact hMerge e he
               · rw [he]; exact hBuiltin b hb
             · exact hMerge e he)
        )

/-- Corollary: checkEffects is monotone in tier —
    if it passes at a lower tier, it passes at a higher tier. -/
theorem checkEffects_mono (fuel : Nat) (expr : SExpr) (t1 t2 : EffLevel)
    (h12 : t1 ≤ t2)
    (hCheck : checkEffects fuel expr t1 = true) :
    checkEffects fuel expr t2 = true := by
  induction fuel generalizing expr with
  | zero => simp [checkEffects] at hCheck
  | succ n ih =>
    match expr with
    | .sym s =>
      simp [checkEffects] at *
      exact symbolAllowed_mono s t1 t2 h12 hCheck
    | .str _ => simp [checkEffects]
    | .num _ => simp [checkEffects]
    | .slist [] => simp [checkEffects]
    | .slist (head :: args) =>
      simp only [checkEffects, Bool.and_eq_true, List.all_eq_true] at *
      exact ⟨ih head hCheck.1, fun a ha => ih a (hCheck.2 a ha)⟩

/-- Pure built-ins are classified as pure. -/
theorem pure_builtins_pure :
    ∀ (b : Builtin), b.effLevel = .pure →
    EffLevel.le b.effLevel .pure = true := by
  intro b hb
  simp [EffLevel.le, EffLevel.toNat, hb]

/-- Effectful built-ins are above pure. -/
theorem replayable_above_pure :
    EffLevel.le EffLevel.replayable EffLevel.pure = false := by
  simp [EffLevel.le, EffLevel.toNat]

theorem nonReplayable_above_pure :
    EffLevel.le EffLevel.nonReplayable EffLevel.pure = false := by
  simp [EffLevel.le, EffLevel.toNat]

theorem nonReplayable_above_replayable :
    EffLevel.le EffLevel.nonReplayable EffLevel.replayable = false := by
  simp [EffLevel.le, EffLevel.toNat]

/-- checkEffects rejects effectful symbols at pure tier. -/
theorem checkEffects_rejects_llm_at_pure (fuel : Nat) (hf : fuel > 0) :
    checkEffects fuel (.sym "llm-call") .pure = false := by
  match fuel with
  | n + 1 =>
    simp [checkEffects, symbolAllowed, resolveBuiltin, Builtin.effLevel,
          EffLevel.le, EffLevel.toNat]

/-- checkEffects accepts pure symbols at pure tier. -/
theorem checkEffects_accepts_add_at_pure (fuel : Nat) (hf : fuel > 0) :
    checkEffects fuel (.sym "+") .pure = true := by
  match fuel with
  | n + 1 =>
    simp [checkEffects, symbolAllowed, resolveBuiltin, Builtin.effLevel,
          EffLevel.le, EffLevel.toNat]

/-- checkEffects accepts effectful symbols at their own tier. -/
theorem checkEffects_accepts_llm_at_replayable (fuel : Nat) (hf : fuel > 0) :
    checkEffects fuel (.sym "llm-call") .replayable = true := by
  match fuel with
  | n + 1 =>
    simp [checkEffects, symbolAllowed, resolveBuiltin, Builtin.effLevel,
          EffLevel.le, EffLevel.toNat]

end ExprSemantics
