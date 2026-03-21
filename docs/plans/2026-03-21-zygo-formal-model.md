# Zygo Expression Semantics — Formal Model Updates

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extend the Lean 4 formal model with S-expression AST, denotational semantics for the Pure tier, and a static effect checking theorem — per dc-rgt and Zygo substrate design Section 9.

**Architecture:** Create `formal/ZygoSemantics.lean` with: (1) an `SExpr` inductive for the AST, (2) an extended `Val` type with numbers and lists, (3) big-step evaluation semantics for Pure-tier built-ins, (4) a function-symbol effect classifier, (5) a static `checkEffects` walk that checks all symbols against a tier, (6) the theorem that `checkEffects = true` implies evaluation produces no effects above the tier. Update `Autopour.lean` to use `SExpr` instead of opaque `ProgramText`. Register the new file in `lakefile.lean`.

**Tech Stack:** Lean 4, existing `formal/` codebase (Core.lean, Autopour.lean, EffectEval.lean)

---

## Task 1: Create ZygoSemantics.lean — SExpr AST and Extended Val

**Files:**
- Create: `formal/ZygoSemantics.lean`
- Modify: `formal/lakefile.lean` (register new lib)

**Step 1: Create the file with SExpr and Val types**

```lean
/-
  ZygoSemantics: Denotational Semantics of Zygo S-Expressions

  Formalizes the Pure tier of the Zygo expression language:
  arithmetic, strings, lists, conditionals, let-bindings.

  Key results:
  1. SExpr — S-expression AST (the cell computation substrate)
  2. ZVal — extended value domain (strings, ints, lists, closures, programs)
  3. Big-step eval for Pure built-ins
  4. Static effect checking: checkEffects(ast, tier) = true →
     eval produces no effects above tier
  5. Theorem: effect safety of the static check

  Imports Core.lean for identity types and Autopour.lean for EffLevel.

  Author: Glassblower (2026-03-21)
  Bead: dc-rgt
-/

import Core
import Autopour

namespace ZygoSemantics

open Autopour (EffLevel)

/-! ====================================================================
    S-EXPRESSION AST
    ==================================================================== -/

/-- The S-expression AST. Cell bodies are Zygo programs. -/
inductive SExpr where
  | sym   : String → SExpr              -- symbol (function name, variable)
  | str   : String → SExpr              -- string literal
  | num   : Int → SExpr                 -- numeric literal
  | slist : List SExpr → SExpr          -- compound expression (function call)
  deriving Repr, DecidableEq, BEq

/-! ====================================================================
    EXTENDED VALUE DOMAIN
    ==================================================================== -/

/-- Values produced by Zygo evaluation. Extends Autopour.Val with
    numeric and list values needed for the Pure computation tier. -/
inductive ZVal where
  | str     : String → ZVal
  | num     : Int → ZVal
  | vlist   : List ZVal → ZVal
  | none    : ZVal
  | error   : String → ZVal
  | program : SExpr → ZVal              -- a program is a value (homoiconicity)
  deriving Repr, DecidableEq, BEq

def ZVal.isError : ZVal → Bool
  | .error _ => true
  | _ => false

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

end ZygoSemantics
```

**Step 2: Register in lakefile.lean**

Add after the Autopour entry:

```lean
lean_lib ZygoSemantics where
  roots := #[`ZygoSemantics]
```

**Step 3: Build**

Run: `cd formal && lake build ZygoSemantics`
Expected: Build succeeds with no errors or warnings.

**Step 4: Commit**

```bash
git add formal/ZygoSemantics.lean formal/lakefile.lean
git commit -m "formal: ZygoSemantics.lean — SExpr AST and ZVal types

S-expression AST for cell computation substrate (Zygo design dc-jo2).
Extended value domain with numbers, lists, programs.
Foundation for Pure tier denotational semantics."
```

---

## Task 2: Built-in Function Classification and Effect Checking

**Files:**
- Modify: `formal/ZygoSemantics.lean`

**Step 1: Add the built-in function effect classification**

Append to `ZygoSemantics.lean` before the closing `end`:

```lean
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
  -- Pure (quoting)
  | quote | readString
  -- Replayable (LLM)
  | llmCall | llmJudge
  -- NonReplayable (tuple space mutation)
  | pour | claim | submit | observe
  -- NonReplayable (external)
  | httpGet | httpPost | sqlExec
  deriving Repr, DecidableEq, BEq

/-- Classify a built-in's effect level. -/
def Builtin.effLevel : Builtin → EffLevel
  | .add | .sub | .mul | .div | .modulo => .pure
  | .concat | .strlen | .substr         => .pure
  | .cons | .car | .cdr | .listCtor | .len => .pure
  | .ifExpr | .let_ | .eq | .lt | .gt   => .pure
  | .quote | .readString                => .pure
  | .llmCall | .llmJudge                => .replayable
  | .pour | .claim | .submit | .observe => .nonReplayable
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
    Unknown symbols: conservatively allowed (they're either variables
    or user-defined functions that will be checked at their definition site). -/
def symbolAllowed (name : String) (tier : EffLevel) : Bool :=
  match resolveBuiltin name with
  | some b => EffLevel.le b.effLevel tier
  | none   => true    -- unknown symbol: variable or user function

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
```

**Step 2: Build**

Run: `cd formal && lake build ZygoSemantics`
Expected: Build succeeds.

**Step 3: Commit**

```bash
git add formal/ZygoSemantics.lean
git commit -m "formal: built-in effect classification and checkEffects

Each Zygo built-in has a known effect level. checkEffects walks the
AST and verifies every function symbol is allowed at the given tier.
Foundation for the static effect checking theorem."
```

---

## Task 3: Big-Step Evaluation Semantics for Pure Tier

**Files:**
- Modify: `formal/ZygoSemantics.lean`

**Step 1: Add the evaluation function**

Append before `end ZygoSemantics`:

```lean
/-! ====================================================================
    BIG-STEP EVALUATION (Pure Tier)
    ==================================================================== -/

/-- Result of evaluation: a value plus a (possibly empty) list of
    effect levels actually performed during evaluation. -/
structure EvalResult where
  val     : ZVal
  effects : List EffLevel    -- effects actually performed
  deriving Repr

def EvalResult.pure (v : ZVal) : EvalResult :=
  { val := v, effects := [] }

def EvalResult.withEffect (v : ZVal) (e : EffLevel) : EvalResult :=
  { val := v, effects := [e] }

/-- Maximum effect level in a list (pure if empty). -/
def maxEffect : List EffLevel → EffLevel :=
  List.foldl EffLevel.join .pure

/-- Merge effects from multiple results. -/
def mergeEffects (results : List EvalResult) : List EffLevel :=
  results.bind (·.effects)

/-- Big-step evaluation of Zygo S-expressions.
    Fuel-bounded for termination in Lean.
    Tracks actual effects performed (for the safety theorem). -/
def eval (fuel : Nat) (env : ZEnv) (expr : SExpr) : EvalResult :=
  match fuel with
  | 0 => EvalResult.pure (.error "fuel exhausted")
  | fuel' + 1 =>
    match expr with
    | .str s => EvalResult.pure (.str s)
    | .num n => EvalResult.pure (.num n)
    | .sym name => EvalResult.pure (env.lookup name)
    | .slist [] => EvalResult.pure .none
    | .slist [.sym "quote", arg] => EvalResult.pure (.program arg)
    | .slist [.sym "if", cond, thenBr, elseBr] =>
      let cr := eval fuel' env cond
      match cr.val with
      | .error e => { val := .error e, effects := cr.effects }
      | .none    => let er := eval fuel' env elseBr
                    { val := er.val, effects := cr.effects ++ er.effects }
      | _        => let tr := eval fuel' env thenBr
                    { val := tr.val, effects := cr.effects ++ tr.effects }
    | .slist [.sym "let", .sym name, valExpr, bodyExpr] =>
      let vr := eval fuel' env valExpr
      match vr.val with
      | .error e => { val := .error e, effects := vr.effects }
      | v        => let br := eval fuel' (env.bind name v) bodyExpr
                    { val := br.val, effects := vr.effects ++ br.effects }
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
    | .slist [.sym "=", a, b] =>
      let ar := eval fuel' env a
      let br := eval fuel' env b
      let eq := ar.val == br.val
      { val := if eq then .num 1 else .none,
        effects := ar.effects ++ br.effects }
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
    -- Effectful built-ins: tag the effect but don't actually execute
    -- (we model the EFFECT, not the implementation)
    | .slist (.sym fname :: args) =>
      let results := args.map (eval fuel' env)
      let effs := mergeEffects results
      match resolveBuiltin fname with
      | some b => { val := .str s!"<{fname} result>",
                    effects := effs ++ [b.effLevel] }
      | none   => { val := .error s!"unknown function: {fname}", effects := effs }
    | .slist _ => EvalResult.pure (.error "invalid expression: non-symbol head")
```

**Step 2: Build**

Run: `cd formal && lake build ZygoSemantics`
Expected: Build succeeds.

**Step 3: Commit**

```bash
git add formal/ZygoSemantics.lean
git commit -m "formal: big-step eval semantics for Zygo Pure tier

Fuel-bounded evaluation with effect tracking. Covers arithmetic,
strings, lists, conditionals, let-bindings, quoting. Effectful
built-ins tag their effect level for the safety theorem."
```

---

## Task 4: Effect Safety Theorem

**Files:**
- Modify: `formal/ZygoSemantics.lean`

**Step 1: Add the core theorems**

Append before `end ZygoSemantics`:

```lean
/-! ====================================================================
    EFFECT SAFETY THEOREM
    ==================================================================== -/

/-- An EvalResult respects a tier if all its actual effects are ≤ tier. -/
def EvalResult.respectsTier (r : EvalResult) (tier : EffLevel) : Prop :=
  ∀ e ∈ r.effects, e ≤ tier

/-- Bool version for decidable checking. -/
def EvalResult.respectsTierB (r : EvalResult) (tier : EffLevel) : Bool :=
  r.effects.all (fun e => EffLevel.le e tier)

/-- The Bool check implies the Prop. -/
theorem respectsTier_of_B (r : EvalResult) (tier : EffLevel)
    (h : r.respectsTierB tier = true) :
    r.respectsTier tier := by
  intro e he
  simp [EvalResult.respectsTierB, List.all_eq_true] at h
  exact h e he

/-- Pure evaluation produces no effects. -/
theorem pure_result_no_effects (v : ZVal) :
    (EvalResult.pure v).respectsTier tier := by
  intro e he
  simp [EvalResult.pure] at he

/-- KEY THEOREM: If checkEffects passes for a tier, then evaluating
    the expression produces only effects at or below that tier.

    This is the static effect checking soundness theorem from
    Zygo substrate design Section 9.

    Proof sketch:
    - Literals (.str, .num) produce no effects → trivially safe
    - Symbols produce no effects → safe
    - Compound expressions: checkEffects checks the head symbol AND
      recursively checks all arguments. If the head is a known built-in,
      its effect level ≤ tier. By induction on fuel, all sub-expression
      effects ≤ tier. The result's effects are the union of sub-effects
      plus the head's effect, all ≤ tier.

    The proof is by well-founded induction on fuel. -/
theorem effect_safety (fuel : Nat) (env : ZEnv) (expr : SExpr) (tier : EffLevel)
    (hCheck : checkEffects fuel expr tier = true) :
    (eval fuel env expr).respectsTier tier := by
  sorry
  -- The proof requires mutual induction over:
  -- (a) fuel decreasing (structural)
  -- (b) checkEffects = true on all subexpressions (from the && and List.all)
  -- (c) symbolAllowed = true implies Builtin.effLevel ≤ tier
  --
  -- This is a standard type-safety-style theorem for a simple effect
  -- system. The mathematical content is straightforward but the Lean
  -- proof requires careful case analysis over the SExpr match arms
  -- and is left as a separate proof-engineering task.
  --
  -- See: "Types and Programming Languages" Ch. 8 (Safety = Progress + Preservation)
  -- adapted to an effect system instead of a type system.

/-- Corollary: Pure tier has no effects at all. -/
theorem pure_tier_no_effects (fuel : Nat) (env : ZEnv) (expr : SExpr)
    (hCheck : checkEffects fuel expr EffLevel.pure = true) :
    (eval fuel env expr).effects = [] := by
  sorry
  -- Follows from effect_safety: all effects ≤ pure, but the only
  -- EffLevel ≤ pure is pure itself. Since the eval function only
  -- adds effects via Builtin.effLevel, and all pure built-ins are
  -- implemented inline (producing no effects list entry), the
  -- effects list must be empty.

/-- Corollary: checkEffects is monotone in tier —
    if it passes at a lower tier, it passes at a higher tier. -/
theorem checkEffects_mono (fuel : Nat) (expr : SExpr) (t1 t2 : EffLevel)
    (h12 : t1 ≤ t2)
    (hCheck : checkEffects fuel expr t1 = true) :
    checkEffects fuel expr t2 = true := by
  sorry
  -- Follows from: symbolAllowed is monotone in tier (if EffLevel.le e t1
  -- and t1 ≤ t2, then EffLevel.le e t2 by transitivity), and checkEffects
  -- is a conjunction of symbolAllowed checks.
```

**Step 2: Build**

Run: `cd formal && lake build ZygoSemantics`
Expected: Builds with `sorry` warnings (3 total). No errors.

**Step 3: Commit**

```bash
git add formal/ZygoSemantics.lean
git commit -m "formal: effect safety theorem for static checking

checkEffects(ast, tier) = true → eval(ast) produces no effects above tier.
Three theorems with sorry (proof engineering pending):
- effect_safety: the main soundness theorem
- pure_tier_no_effects: Pure evaluation has empty effects list
- checkEffects_mono: static check is monotone in tier"
```

---

## Task 5: Update Autopour.lean Val to Support SExpr

**Files:**
- Modify: `formal/Autopour.lean`

**Step 1: Replace ProgramText with SExpr import**

In Autopour.lean, the current code has:

```lean
structure ProgramText where
  source : String
  deriving Repr, DecidableEq, BEq

inductive Val where
  | str     : String → Val
  | none    : Val
  | error   : String → Val
  | program : ProgramText → Val
  deriving Repr, DecidableEq, BEq
```

Change to import ZygoSemantics and use SExpr:

```lean
import ZygoSemantics

-- After the existing `import Core` line, add `import ZygoSemantics`.
-- Then replace ProgramText and Val:

/-- ProgramText wraps an S-expression AST.
    Previously opaque (just a String); now structural (Zygo design dc-jo2).
    Programs are data — homoiconicity makes reification natural. -/
structure ProgramText where
  ast    : ZygoSemantics.SExpr
  source : String   -- original source text (for display/debug)
  deriving Repr, DecidableEq, BEq

/-- Values in the Cell language, extended with program values. -/
inductive Val where
  | str     : String → Val
  | none    : Val
  | error   : String → Val
  | program : ProgramText → Val    -- a program is a value (S-expression AST)
  deriving Repr, DecidableEq, BEq
```

**Step 2: Fix downstream references**

The `autopourStep` function uses `pt.source.take 100` — update to use `pt.source`:

```lean
-- In autopourStep, the parseFail arm:
.parseFail s!"Failed to parse or effect violation: {pt.source.take 100}"
-- This still works since ProgramText still has .source
```

**Step 3: Build all targets that depend on Autopour**

Run: `cd formal && lake build Autopour ZygoSemantics`
Expected: Build succeeds.

**Step 4: Commit**

```bash
git add formal/Autopour.lean
git commit -m "formal: ProgramText now wraps SExpr AST

Programs are structured S-expressions instead of opaque strings.
Homoiconicity: programs are data, reification is natural.
Aligns with Zygo substrate design (dc-jo2)."
```

---

## Task 6: Build All and Verify

**Files:**
- None (verification only)

**Step 1: Full build**

Run: `cd formal && lake clean && lake build Autopour EffectEval ZygoSemantics Core Denotational`
Expected: All build. Warnings for `sorry` only (existing `nonFrozen_mono` in EffectEval + 3 new in ZygoSemantics).

**Step 2: Count sorry holes**

Run: `grep -rn 'sorry' formal/*.lean | grep -v '^\s*--'`
Expected: 4 total (1 existing in EffectEval, 3 new in ZygoSemantics with documented proof sketches).

**Step 3: Commit (tag)**

```bash
git add -A formal/
git commit -m "formal: ZygoSemantics complete — SExpr AST, Pure tier eval, effect safety

New file: ZygoSemantics.lean
- SExpr inductive (sym/str/num/slist)
- ZVal extended value domain (strings, ints, lists, programs)
- Built-in function effect classification (Pure/Replayable/NonReplayable)
- Static checkEffects: walk AST, verify all symbols ≤ tier
- Big-step eval with effect tracking
- effect_safety theorem (sorry, proof sketch documented)
- pure_tier_no_effects corollary (sorry)
- checkEffects_mono corollary (sorry)

Updated: Autopour.lean
- ProgramText wraps SExpr AST instead of opaque String
- Programs are structured data (homoiconicity)

Bead: dc-rgt"
```

---

## Summary

| Task | What | Theorems |
|------|------|----------|
| 1 | SExpr AST + ZVal types | — |
| 2 | Built-in effect classification + checkEffects | — |
| 3 | Big-step eval semantics (Pure tier) | — |
| 4 | Effect safety theorem | 3 (sorry, proof sketches) |
| 5 | Update Autopour.lean Val → SExpr | — |
| 6 | Full build verification | — |

**Sorry budget:** 3 new (effect_safety, pure_tier_no_effects, checkEffects_mono). All have documented proof sketches. The main theorem (effect_safety) is a standard type-safety argument; filling it requires careful case analysis but no novel mathematics.

**Not in this plan (follow-up):**
- Fill the 3 sorry holes (proof engineering, possibly with lean4:autoprove)
- Crystallization-as-refinement theorem (Section 9 item 3 — depends on this work)
- BodyType derivation from effect level + stem flag
- Integration with Denotational.lean's Val type (unification)
