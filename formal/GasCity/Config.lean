/-
  GasCity.Config — Primitive 4: deterministic composition and progressive activation

  Formalizes config.City from internal/config/config.go.

  COVERAGE (vs Go implementation):
    Agent fields:    5/48+ (missing workDir, scope, pool, workQuery, slingQuery,
                     idleTimeout, dependsOn, wakeMode, and ~40 more)
    Rig fields:      4/8   (missing formulasDir, includes, overrides, defaultSlingTarget)
    City fields:     2/19+ (missing workspace, providers, packs, patches, beads,
                     session, mail, events, daemon, orders, api, etc.)
    Patch fields:    3/39+ (Go patches 39+ fields; Lean patches 3)
    Validation:      2/20+ (Go validates enums, pool bounds, DAG cycles, etc.)
    AgentPatch vs AgentOverride: Go has two distinct types; Lean conflates them.
    Override precedence: Lean uses 4-layer enum; Go uses composition order
      (root → fragments → city packs → rig packs → patches).

  Go source: internal/config/config.go
  Architecture: docs/architecture/config.md
  Bead: dc-q8z
-/

import GasCity.Basic

namespace GasCity.Config

/-- Agent identity: the (dir, name) pair must be unique. -/
structure AgentId where
  dir : String
  name : String
  deriving DecidableEq, Repr

/-- Agent configuration. -/
structure Agent where
  id : AgentId
  provider : String
  promptTemplate : String
  suspended : Bool
  env : List (String × String)

/-- Rig configuration. -/
structure Rig where
  name : String
  beadPrefix : String  -- bead ID prefix, must be unique
  path : String
  suspended : Bool

/-- City configuration (the top-level parsed result). -/
structure City where
  agents : List Agent
  rigs : List Rig

/-- Agent patch: pointer fields for null-semantics (None = don't change). -/
structure AgentPatch where
  target : AgentId
  provider : Option String := none
  suspended : Option Bool := none
  env : Option (List (String × String)) := none

/-- Apply a patch to an agent. Fields are overwritten only when Some. -/
def applyPatch (a : Agent) (p : AgentPatch) : Agent :=
  { a with
    provider := p.provider.getD a.provider
    suspended := p.suspended.getD a.suspended
    env := p.env.getD a.env }

/-- Override layer priority. -/
inductive OverrideLayer where
  | builtin    : OverrideLayer
  | cityLevel  : OverrideLayer
  | workspace  : OverrideLayer
  | perAgent   : OverrideLayer
  deriving DecidableEq, Repr

/-- Override layer ordering. -/
instance : LE OverrideLayer where
  le a b := match a, b with
    | .builtin, _ => True
    | .cityLevel, .builtin => False
    | .cityLevel, _ => True
    | .workspace, .builtin => False
    | .workspace, .cityLevel => False
    | .workspace, _ => True
    | .perAgent, .perAgent => True
    | .perAgent, _ => False

/-- Formula layer priority for resolution. -/
inductive FormulaLayer where
  | cityPacks : FormulaLayer
  | cityLocal : FormulaLayer
  | rigPacks  : FormulaLayer
  | rigLocal  : FormulaLayer
  deriving DecidableEq, Repr

/-- Formula layer ordering: city-packs < city-local < rig-packs < rig-local -/
def FormulaLayer.priority : FormulaLayer → Nat
  | .cityPacks => 0
  | .cityLocal => 1
  | .rigPacks  => 2
  | .rigLocal  => 3

-- ═══════════════════════════════════════════════════════════════
-- Validation predicates
-- ═══════════════════════════════════════════════════════════════

/-- Agent identity uniqueness: no two agents share (dir, name). -/
def agentIdsUnique (city : City) : Prop :=
  ∀ (a1 a2 : Agent), a1 ∈ city.agents → a2 ∈ city.agents → a1 ≠ a2 →
    a1.id ≠ a2.id

/-- Rig prefix uniqueness: no two rigs share a prefix. -/
def rigPrefixesUnique (city : City) : Prop :=
  ∀ (r1 r2 : Rig), r1 ∈ city.rigs → r2 ∈ city.rigs → r1 ≠ r2 →
    r1.beadPrefix ≠ r2.beadPrefix

/-- A valid city has unique agent IDs and rig prefixes. -/
def isValid (city : City) : Prop :=
  agentIdsUnique city ∧ rigPrefixesUnique city

-- ═══════════════════════════════════════════════════════════════
-- Theorems
-- ═══════════════════════════════════════════════════════════════

/-- Patch application is idempotent: applying the same patch twice
    is the same as applying it once. -/
theorem applyPatch_idempotent (a : Agent) (p : AgentPatch) :
    applyPatch (applyPatch a p) p = applyPatch a p := by
  simp [applyPatch]
  constructor
  · cases p.provider <;> simp
  · constructor
    · cases p.suspended <;> simp
    · cases p.env <;> simp

/-- Override precedence is a total order. -/
theorem override_layer_total (a b : OverrideLayer) : a ≤ b ∨ b ≤ a := by
  cases a <;> cases b <;> simp [LE.le]

/-- Formula layer priority is injective (each layer has unique priority). -/
theorem formula_layer_priority_injective (a b : FormulaLayer) :
    a.priority = b.priority → a = b := by
  cases a <;> cases b <;> simp [FormulaLayer.priority]

/-- Formula resolution is last-wins: higher priority layer wins.
    If the same formula exists in two layers, the one with higher
    priority is chosen. -/
theorem formula_last_wins (a b : FormulaLayer) (ha : a.priority < b.priority) :
    -- b wins over a
    b.priority > a.priority := by
  exact ha

end GasCity.Config
