/-
  PromptTemplates: Formal Model of Prompt Template Rendering

  Formalizes how soft cell bodies with «field» guillemet references
  get resolved against resolved_inputs (the Env from upstream yields).

  Key properties proved:
  1. Rendering determinism: same PromptContext → same output
  2. Graceful fallback: parse failure → raw template text returned
  3. Field override: SDK fields win over Env for same key
  4. No side effects: rendering is a pure function (read-only)
  5. Template safety: all references resolve or produce defined error

  Self-contained: imports only Core.lean (identity types).
-/

import Core

namespace PromptTemplates

/-! ====================================================================
    VALUE DOMAIN (local copy, matches Denotational/Autopour pattern)
    ==================================================================== -/

inductive Val where
  | str   : String → Val
  | none  : Val
  | error : String → Val
  deriving Repr, DecidableEq, BEq

def Val.isError : Val → Bool
  | .error _ => true
  | _ => false

def Val.toString : Val → String
  | .str s   => s
  | .none    => ""
  | .error e => "«error: " ++ e ++ "»"

/-! ====================================================================
    ENVIRONMENTS
    ==================================================================== -/

abbrev Env := List (FieldName × Val)

def Env.lookup (env : Env) (f : FieldName) : Val :=
  match env.find? (fun p => p.1 == f) with
  | some (_, v) => v
  | none => .none

/-! ====================================================================
    TEMPLATE SEGMENTS
    ==================================================================== -/

/-- A template is a sequence of literal text and field references.
    `«items»` in the template text becomes `Ref ⟨"items"⟩`. -/
inductive Segment where
  | lit : String → Segment       -- literal text
  | ref : FieldName → Segment    -- «field» reference
  deriving Repr, DecidableEq, BEq

/-- A parsed template is a list of segments. -/
abbrev Template := List Segment

/-! ====================================================================
    PROMPT CONTEXT
    ==================================================================== -/

/-- The context for rendering a template.
    `sdkFields` override `env` when both contain the same key. -/
structure PromptContext where
  env       : Env    -- resolved inputs from upstream yields
  sdkFields : Env    -- SDK-provided fields (higher priority)
  deriving Repr

/-- Resolve a field reference: SDK fields win over Env. -/
def PromptContext.resolve (ctx : PromptContext) (f : FieldName) : Val :=
  match ctx.sdkFields.find? (fun p => p.1 == f) with
  | some (_, v) => v
  | none => Env.lookup ctx.env f

/-! ====================================================================
    RENDERING
    ==================================================================== -/

/-- Render a single segment given a context. -/
def renderSegment (ctx : PromptContext) : Segment → String
  | .lit s   => s
  | .ref f   => (ctx.resolve f).toString

/-- Render a full template by concatenating rendered segments. -/
def renderTemplate (ctx : PromptContext) (t : Template) : String :=
  t.map (renderSegment ctx) |>.foldl (· ++ ·) ""

/-- The result of attempting to parse and render a template.
    On success: the rendered string.
    On parse failure: the raw template text is returned unchanged. -/
inductive RenderResult where
  | ok      : String → RenderResult
  | fallback : String → RenderResult   -- raw text returned on parse failure
  deriving Repr, DecidableEq, BEq

/-- Parse and render with graceful fallback.
    If parsing succeeds (template is provided), render it.
    If parsing fails (represented by `none`), return raw text. -/
def renderWithFallback (ctx : PromptContext) (raw : String)
    (parsed : Option Template) : RenderResult :=
  match parsed with
  | some t => .ok (renderTemplate ctx t)
  | none   => .fallback raw

/-! ====================================================================
    SECTION 1: RENDERING DETERMINISM

    Theorem: same PromptContext and same Template always produce
    the same output string. This is trivial for pure functions in
    Lean (definitional equality), but we state it explicitly as
    the formal analog of the spec requirement.
    ==================================================================== -/

/-- Rendering is deterministic: same context and template → same output. -/
theorem render_deterministic (ctx : PromptContext) (t : Template) :
    renderTemplate ctx t = renderTemplate ctx t := rfl

/-- Stronger form: equal contexts and equal templates → equal output. -/
theorem render_deterministic_ext (ctx1 ctx2 : PromptContext) (t1 t2 : Template)
    (hc : ctx1 = ctx2) (ht : t1 = t2) :
    renderTemplate ctx1 t1 = renderTemplate ctx2 t2 := by
  subst hc; subst ht; rfl

/-! ====================================================================
    SECTION 2: GRACEFUL FALLBACK

    Theorem: when parsing fails (Option Template = none),
    renderWithFallback returns the raw text unchanged.
    ==================================================================== -/

/-- Parse failure → raw text returned unchanged. -/
theorem render_fallback (ctx : PromptContext) (raw : String) :
    renderWithFallback ctx raw none = .fallback raw := rfl

/-- Parse success → rendered output returned. -/
theorem render_success (ctx : PromptContext) (raw : String) (t : Template) :
    renderWithFallback ctx raw (some t) = .ok (renderTemplate ctx t) := rfl

/-- The fallback result always contains exactly the raw text. -/
theorem fallback_preserves_raw (ctx : PromptContext) (raw : String) :
    ∃ s, renderWithFallback ctx raw none = .fallback s ∧ s = raw :=
  ⟨raw, rfl, rfl⟩

/-! ====================================================================
    SECTION 3: FIELD OVERRIDE (SDK fields win)

    Theorem: when both sdkFields and env contain a binding for the
    same FieldName, the SDK value is used.
    ==================================================================== -/

/-- Helper: find? returns the first match. -/
private theorem find_cons_hit {α : Type} [BEq α] {p : α → Bool} {a : α} {as : List α}
    (h : p a = true) : (a :: as).find? p = some a := by
  simp [List.find?, h]

/-- SDK field present → SDK value used, regardless of env. -/
theorem sdk_overrides_env (ctx : PromptContext) (f : FieldName) (v : Val)
    (_h : (f, v) ∈ ctx.sdkFields)
    (hFirst : ctx.sdkFields.find? (fun p => p.1 == f) = some (f, v)) :
    ctx.resolve f = v := by
  simp [PromptContext.resolve, hFirst]

/-- When SDK has no binding, env is consulted. -/
theorem env_used_when_no_sdk (ctx : PromptContext) (f : FieldName)
    (h : ctx.sdkFields.find? (fun p => p.1 == f) = none) :
    ctx.resolve f = Env.lookup ctx.env f := by
  simp [PromptContext.resolve, h]

/-- Concrete override scenario: SDK field at head of list. -/
theorem sdk_head_overrides (_env : Env) (f : FieldName) (sdkVal envVal : Val) :
    let ctx := { env := [(f, envVal)], sdkFields := [(f, sdkVal)] : PromptContext }
    ctx.resolve f = sdkVal := by
  simp only [PromptContext.resolve, List.find?]
  rw [beq_self_eq_true]

/-! ====================================================================
    SECTION 4: NO SIDE EFFECTS (rendering is read-only)

    The rendering functions are pure functions that take a context and
    return a string. They cannot modify the context. In Lean 4, this
    is enforced by the type system: the functions are not monadic and
    do not use IO, ST, or any state monad.

    We state this as structural properties of the render output.
    ==================================================================== -/

/-- Rendering an empty template produces empty string. -/
theorem render_empty (ctx : PromptContext) :
    renderTemplate ctx [] = "" := rfl

/-- Rendering preserves context identity (structural purity).
    The context is not consumed or modified — it can be reused. -/
theorem render_reuse (ctx : PromptContext) (t1 t2 : Template) :
    (renderTemplate ctx t1, renderTemplate ctx t2) =
    (renderTemplate ctx t1, renderTemplate ctx t2) := rfl

/-- Rendering a literal segment is independent of context. -/
theorem render_lit_independent (ctx1 ctx2 : PromptContext) (s : String) :
    renderSegment ctx1 (.lit s) = renderSegment ctx2 (.lit s) := rfl

/-- Foldl string concat absorbs accumulator. -/
private theorem foldl_concat_acc (acc : String) (xs : List String) :
    List.foldl (· ++ ·) acc xs = acc ++ List.foldl (· ++ ·) "" xs := by
  induction xs generalizing acc with
  | nil => simp [List.foldl]
  | cons x xs ih =>
    simp only [List.foldl]
    rw [ih (acc ++ x), ih ("" ++ x)]
    simp [String.append_assoc]

/-- Rendering distributes over template concatenation. -/
theorem render_append (ctx : PromptContext) (t1 t2 : Template) :
    renderTemplate ctx (t1 ++ t2) =
    renderTemplate ctx t1 ++ renderTemplate ctx t2 := by
  simp only [renderTemplate, List.map_append]
  rw [List.foldl_append]
  exact foldl_concat_acc _ _

/-! ====================================================================
    SECTION 5: TEMPLATE SAFETY

    All field references in a template either:
    (a) resolve to a concrete value (Val.str), or
    (b) produce a defined result (Val.none → "" or Val.error → error text)

    There is no undefined behavior — every reference path is handled.
    ==================================================================== -/

/-- Every resolved reference produces a well-defined string. -/
theorem resolve_always_defined (ctx : PromptContext) (f : FieldName) :
    ∃ s : String, (ctx.resolve f).toString = s :=
  ⟨(ctx.resolve f).toString, rfl⟩

/-- Val.toString never crashes — every Val variant produces a string. -/
theorem val_toString_total (v : Val) :
    ∃ s : String, v.toString = s := by
  cases v with
  | str s   => exact ⟨s, rfl⟩
  | none    => exact ⟨"", rfl⟩
  | error e => exact ⟨"«error: " ++ e ++ "»", rfl⟩

/-- Every segment renders to a defined string. -/
theorem segment_renders_defined (ctx : PromptContext) (seg : Segment) :
    ∃ s : String, renderSegment ctx seg = s := by
  cases seg with
  | lit s => exact ⟨s, rfl⟩
  | ref f => exact ⟨(ctx.resolve f).toString, rfl⟩

/-- A reference to a missing field (not in SDK or env) renders as "". -/
theorem missing_ref_renders_empty (f : FieldName) :
    let ctx := { env := [], sdkFields := [] : PromptContext }
    renderSegment ctx (.ref f) = "" := by
  simp [renderSegment, PromptContext.resolve, List.find?, Env.lookup, Val.toString]

/-- A reference to an error value renders the error message. -/
theorem error_ref_renders_message (f : FieldName) (msg : String) :
    let ctx := { env := [(f, Val.error msg)], sdkFields := [] : PromptContext }
    renderSegment ctx (.ref f) = "«error: " ++ msg ++ "»" := by
  simp only [renderSegment, PromptContext.resolve, List.find?, Env.lookup]
  rw [beq_self_eq_true]
  simp [Val.toString]

/-! ====================================================================
    COMPOSITION: End-to-end rendering guarantee

    The full pipeline (parse → resolve → render → fallback) always
    produces a defined string result. No path leads to undefined
    behavior or a crash.
    ==================================================================== -/

/-- The full render pipeline always produces a result. -/
theorem pipeline_total (ctx : PromptContext) (raw : String) (parsed : Option Template) :
    ∃ r : RenderResult, renderWithFallback ctx raw parsed = r :=
  ⟨renderWithFallback ctx raw parsed, rfl⟩

/-- The pipeline result is always one of ok or fallback. -/
theorem pipeline_cases (ctx : PromptContext) (raw : String) (parsed : Option Template) :
    (∃ s, renderWithFallback ctx raw parsed = .ok s) ∨
    (∃ s, renderWithFallback ctx raw parsed = .fallback s) := by
  cases parsed with
  | some t => left; exact ⟨renderTemplate ctx t, rfl⟩
  | none   => right; exact ⟨raw, rfl⟩

/-! ====================================================================
    TEMPLATE DISCOVERY / FALLBACK CHAIN
    Multi-level template resolution: SDK → custom → defaults → error
    ==================================================================== -/

/-- Template source layers, ordered by priority. -/
inductive TemplateSource where
  | sdk       -- built-in SDK templates
  | custom    -- user/rig-specific overrides
  | defaults  -- system defaults
  deriving Repr, DecidableEq, BEq

/-- A template registry: maps template names to templates per source. -/
abbrev TemplateRegistry := TemplateSource → String → Option Template

/-- Resolve a template name through the fallback chain.
    Tries custom first, then SDK, then defaults. -/
def resolveTemplate (reg : TemplateRegistry) (name : String) : Option Template :=
  match reg .custom name with
  | some t => some t
  | none => match reg .sdk name with
    | some t => some t
    | none => reg .defaults name

/-- Custom templates override SDK templates. -/
theorem custom_overrides_sdk (reg : TemplateRegistry) (name : String)
    (t : Template) (h : reg .custom name = some t) :
    resolveTemplate reg name = some t := by
  simp [resolveTemplate, h]

/-- SDK templates are used when no custom template exists. -/
theorem sdk_fallback (reg : TemplateRegistry) (name : String)
    (t : Template) (hno : reg .custom name = none) (hsdk : reg .sdk name = some t) :
    resolveTemplate reg name = some t := by
  simp [resolveTemplate, hno, hsdk]

/-- Defaults are last resort when neither custom nor SDK have the template. -/
theorem defaults_last_resort (reg : TemplateRegistry) (name : String)
    (hno : reg .custom name = none) (hnosdk : reg .sdk name = none) :
    resolveTemplate reg name = reg .defaults name := by
  simp [resolveTemplate, hno, hnosdk]

/-- Template syntax validation: a template is valid if it contains no
    unresolved error references. -/
def templateValid (ctx : PromptContext) (t : Template) : Bool :=
  t.all fun seg => match seg with
    | .ref f => match ctx.resolve f with
      | .error _ => false
      | _ => true
    | _ => true

/-- A fully literal template is always valid. -/
theorem literal_template_valid (ctx : PromptContext) (segs : List Segment)
    (h : ∀ s ∈ segs, ∃ t, s = .lit t) :
    templateValid ctx segs = true := by
  induction segs with
  | nil => rfl
  | cons s rest ih =>
    unfold templateValid List.all
    obtain ⟨t, ht⟩ := h s (List.Mem.head _)
    rw [ht]
    simp only [Bool.true_and]
    exact ih (fun s' hs' => h s' (List.Mem.tail _ hs'))

end PromptTemplates
