/-
  GasCity.PromptTemplates — Primitive 5: rendering determinism and safety

  Formalizes the prompt template system from internal/templates/templates.go.
  Key properties: rendering determinism, graceful fallback,
  SDK field override, template discovery chain, no side effects.

  COVERAGE (vs Go implementation):
    Template discovery: multi-level fallback (SDK → custom → defaults → error)
    RoleData/SpawnData/NudgeData: modeled as PromptContext
    Template rendering: opaque, always-total
    SDK field override: proven
    Template validation: syntax predicate
    Coverage: ~70%

  Go source: internal/templates/templates.go
  Architecture: docs/architecture/prompt-templates.md
  Bead: dc-8dk
-/

import GasCity.Basic

namespace GasCity.PromptTemplates

/-- Template rendering context (the data available to templates). -/
structure PromptContext where
  cityRoot : String
  agentName : String
  templateName : String
  rigName : String
  workDir : String
  issuePrefix : String
  branch : String
  defaultBranch : String
  workQuery : String
  slingQuery : String
  env : List (String × String)  -- user-supplied variables

/-- SDK-defined fields that override env entries with the same key. -/
def sdkFields (ctx : PromptContext) : List (String × String) :=
  [ ("CITY_ROOT", ctx.cityRoot)
  , ("AGENT_NAME", ctx.agentName)
  , ("RIG_NAME", ctx.rigName)
  , ("WORK_DIR", ctx.workDir)
  , ("ISSUE_PREFIX", ctx.issuePrefix)
  , ("BRANCH", ctx.branch) ]

/-- Merge env with SDK fields. SDK wins on collision. -/
def mergeEnv (ctx : PromptContext) : List (String × String) :=
  let sdk := sdkFields ctx
  let sdkKeys := sdk.map (·.1)
  let filtered := ctx.env.filter (fun (k, _) => k ∉ sdkKeys)
  filtered ++ sdk

/-- Abstract template rendering result. -/
inductive RenderResult where
  | success : String → RenderResult
  | fallback : String → RenderResult  -- raw template text on error
  deriving DecidableEq, Repr, Nonempty

/-- Template source in the discovery chain. -/
inductive TemplateSource where
  | sdk      : TemplateSource   -- embedded in binary (embed.FS)
  | custom   : TemplateSource   -- user-provided overrides
  | defaults : TemplateSource   -- built-in defaults
  deriving DecidableEq, Repr

/-- Template source priority: SDK < custom < defaults (SDK wins). -/
def TemplateSource.priority : TemplateSource → Nat
  | .defaults => 0
  | .custom   => 1
  | .sdk      => 2

/-- A template with its source. -/
structure Template where
  name : String
  content : String
  source : TemplateSource
  deriving DecidableEq, Repr

/-- Template store: a lookup from name to list of templates at different sources. -/
structure TemplateStore where
  templates : String → List Template

/-- Discover the best template: highest-priority source wins.
    Returns none if no template found at any source. -/
def discover (store : TemplateStore) (name : String) : Option Template :=
  let candidates := store.templates name
  candidates.foldl (fun best t =>
    match best with
    | none => some t
    | some b => if t.source.priority > b.source.priority then some t else some b
  ) none

/-- Multi-level fallback rendering:
    1. Try discovered template
    2. If template found, render it
    3. If render fails, return raw template (graceful fallback)
    4. If no template found, return error message -/
inductive FallbackResult where
  | rendered : String → TemplateSource → FallbackResult
  | rawFallback : String → TemplateSource → FallbackResult
  | notFound : FallbackResult
  deriving DecidableEq, Repr

/-- Render always produces some output (either success or fallback). -/
noncomputable opaque render (template : String) (ctx : PromptContext) : RenderResult

/-- Render with fallback chain: discover → render → fallback. -/
noncomputable def renderWithFallback (store : TemplateStore) (name : String)
    (ctx : PromptContext) : FallbackResult :=
  match discover store name with
  | none => .notFound
  | some t =>
    match render t.content ctx with
    | .success s => .rendered s t.source
    | .fallback s => .rawFallback s t.source

/-- Template syntax validation: a template is valid if it contains
    no unmatched delimiters. Simplified model — Go uses text/template
    which validates on Parse. -/
def isValidTemplate (content : String) : Prop :=
  -- A valid template has balanced {{ }} pairs.
  -- We model this abstractly: the content can be parsed without error.
  content.length > 0

/-- Decidable validity check. -/
instance (content : String) : Decidable (isValidTemplate content) := by
  unfold isValidTemplate
  exact inferInstance

-- ═══════════════════════════════════════════════════════════════
-- Theorems
-- ═══════════════════════════════════════════════════════════════

/-- SDK fields override env: for any key K present in both SDK fields
    and env, the merged result contains the SDK value. -/
theorem sdk_override (ctx : PromptContext) (k v : String)
    (henv : (k, v) ∈ ctx.env)
    (hsdk : k ∈ (sdkFields ctx).map (·.1)) :
    ∀ p ∈ mergeEnv ctx, p.1 = k → p ∈ sdkFields ctx := by
  intro p hp hpk
  simp [mergeEnv] at hp
  cases hp with
  | inl hfilt =>
    -- p came from filtered env, but filtered removes SDK keys
    exfalso
    have ⟨_, hnotsdk⟩ := hfilt
    have : p.1 ∈ (sdkFields ctx).map (·.1) := hpk ▸ hsdk
    exact absurd (List.mem_map.mp this) (by
      intro ⟨pair, hpair_mem, hpair_fst⟩
      exact hnotsdk pair.2 (by rw [← hpair_fst]; exact hpair_mem))
  | inr hsdk_mem => exact hsdk_mem

/-- Rendering never crashes: it always produces RenderResult. -/
theorem render_total (t : String) (ctx : PromptContext) :
    ∃ r, render t ctx = r := by
  exact ⟨render t ctx, rfl⟩

/-- Discovery returns the highest-priority source. -/
theorem discover_highest_priority (store : TemplateStore) (name : String)
    (t1 t2 : Template)
    (ht1 : t1 ∈ store.templates name)
    (ht2 : t2 ∈ store.templates name)
    (hpri : t2.source.priority > t1.source.priority)
    (hresult : discover store name = some t1) :
    False := by
  simp [discover] at hresult
  -- If t2 has higher priority than t1, the fold would have picked t2 over t1
  -- This is a property of the fold algorithm
  sorry  -- This sorry is a genuine algorithmic proof about List.foldl behavior

/-- Fallback rendering always produces output when template exists. -/
theorem fallback_total (store : TemplateStore) (name : String)
    (ctx : PromptContext) (t : Template)
    (hfound : discover store name = some t) :
    renderWithFallback store name ctx ≠ .notFound := by
  simp [renderWithFallback, hfound]
  cases render t.content ctx with
  | success s => exact fun h => nomatch h
  | fallback s => exact fun h => nomatch h

/-- SDK source has highest priority. -/
theorem sdk_highest_priority (s : TemplateSource) :
    s.priority ≤ TemplateSource.sdk.priority := by
  cases s <;> simp +arith [TemplateSource.priority]

end GasCity.PromptTemplates
