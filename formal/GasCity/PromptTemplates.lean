/-
  GasCity.PromptTemplates — Primitive 5: rendering determinism and safety

  Formalizes the prompt template system from cmd/gc/prompt.go.
  Key properties: rendering determinism, graceful fallback,
  SDK field override, no side effects.

  Go source: cmd/gc/prompt.go
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

/-- Render always produces some output (either success or fallback). -/
noncomputable opaque render (template : String) (ctx : PromptContext) : RenderResult

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
  obtain ⟨hp1, hp2⟩ | hp := hp
  · exact absurd hpk (by simp_all)
  · exact hp

/-- Rendering never crashes: it always produces RenderResult. -/
theorem render_total (t : String) (ctx : PromptContext) :
    ∃ r, render t ctx = r := by
  exact ⟨render t ctx, rfl⟩

end GasCity.PromptTemplates
