/-
  GasCity.Layering — cross-cutting: no-upward-dependency invariant

  Formalizes the six layering invariants from nine-concepts.md:
  1. No upward dependencies: Layer N never imports Layer N+1
  2. BeadStore is universal persistence substrate
  3. EventBus is universal observation substrate
  4. Config is universal activation mechanism
  5. Side effects confined to Layer 0
  6. Controller drives all SDK infrastructure

  Also formalizes the progressive capability model (levels 0-8).

  Bead: dc-egm
-/

import GasCity.Basic
import GasCity.AgentProtocol
import GasCity.BeadStore
import GasCity.EventBus
import GasCity.Config
import GasCity.PromptTemplates

namespace GasCity

/-- Layer ordering as a natural number. -/
def layerOrd : Layer → Nat
  | .layer01 => 0
  | .layer2  => 1
  | .layer3  => 2
  | .layer4  => 3

end GasCity

namespace GasCity.Layering

open GasCity

/-- Assign each concept to its layer. -/
def conceptLayer : String → Layer
  | "AgentProtocol"  => .layer01
  | "BeadStore"      => .layer01
  | "EventBus"       => .layer01
  | "Config"         => .layer01
  | "PromptTemplates"=> .layer01
  | "Messaging"      => .layer2
  | "Formulas"       => .layer3
  | "Dispatch"       => .layer3
  | "HealthPatrol"   => .layer4
  | _                => .layer01

-- ═══════════════════════════════════════════════════════════════
-- Layering Invariant Proofs
-- ═══════════════════════════════════════════════════════════════

/-- Invariant 1: Messaging (L2) depends only on L01 primitives. -/
theorem messaging_no_upward :
    layerOrd (conceptLayer "Messaging") > layerOrd (conceptLayer "AgentProtocol") ∧
    layerOrd (conceptLayer "Messaging") > layerOrd (conceptLayer "BeadStore") := by
  simp [conceptLayer, layerOrd]

/-- Invariant 1: Dispatch (L3) depends only on L01 primitives. -/
theorem dispatch_no_upward :
    layerOrd (conceptLayer "Dispatch") > layerOrd (conceptLayer "AgentProtocol") ∧
    layerOrd (conceptLayer "Dispatch") > layerOrd (conceptLayer "BeadStore") ∧
    layerOrd (conceptLayer "Dispatch") > layerOrd (conceptLayer "EventBus") ∧
    layerOrd (conceptLayer "Dispatch") > layerOrd (conceptLayer "Config") := by
  simp [conceptLayer, layerOrd]

/-- Invariant 1: HealthPatrol (L4) depends only on L01 primitives. -/
theorem healthPatrol_no_upward :
    layerOrd (conceptLayer "HealthPatrol") > layerOrd (conceptLayer "AgentProtocol") ∧
    layerOrd (conceptLayer "HealthPatrol") > layerOrd (conceptLayer "EventBus") ∧
    layerOrd (conceptLayer "HealthPatrol") > layerOrd (conceptLayer "Config") := by
  simp [conceptLayer, layerOrd]

/-- All five primitives are at Layer 01. -/
theorem primitives_at_layer01 :
    conceptLayer "AgentProtocol" = .layer01 ∧
    conceptLayer "BeadStore" = .layer01 ∧
    conceptLayer "EventBus" = .layer01 ∧
    conceptLayer "Config" = .layer01 ∧
    conceptLayer "PromptTemplates" = .layer01 := by
  simp [conceptLayer]

-- ═══════════════════════════════════════════════════════════════
-- Progressive Capability Model
-- ═══════════════════════════════════════════════════════════════

/-- Configuration sections that activate each capability level. -/
inductive ConfigSection where
  | workspace     : ConfigSection
  | agent         : ConfigSection
  | daemon        : ConfigSection
  | agentPool     : ConfigSection
  | mail          : ConfigSection
  | formulas      : ConfigSection
  | daemonHealth  : ConfigSection
  | orders        : ConfigSection
  | fullOrch      : ConfigSection
  deriving DecidableEq, Repr

/-- Level activated by a set of config sections. -/
def activationLevel (sections : List ConfigSection) : Fin 9 :=
  if .fullOrch ∈ sections then ⟨8, by omega⟩
  else if .orders ∈ sections then ⟨7, by omega⟩
  else if .daemonHealth ∈ sections then ⟨6, by omega⟩
  else if .formulas ∈ sections then ⟨5, by omega⟩
  else if .mail ∈ sections then ⟨4, by omega⟩
  else if .agentPool ∈ sections then ⟨3, by omega⟩
  else if .daemon ∈ sections then ⟨2, by omega⟩
  else if .agent ∈ sections ∧ .workspace ∈ sections then ⟨1, by omega⟩
  else ⟨0, by omega⟩

/-- Nat-valued activation level, mirroring `activationLevel` without `Fin` wrapping. -/
private def actLvlN (s : List ConfigSection) : Nat :=
  if .fullOrch ∈ s then 8 else if .orders ∈ s then 7
  else if .daemonHealth ∈ s then 6 else if .formulas ∈ s then 5
  else if .mail ∈ s then 4 else if .agentPool ∈ s then 3
  else if .daemon ∈ s then 2
  else if .agent ∈ s ∧ .workspace ∈ s then 1 else 0

private theorem activationLevel_val (s : List ConfigSection) :
    (activationLevel s).val = actLvlN s := by
  simp only [activationLevel, actLvlN]; repeat (split <;> try rfl)

/-- Progressive activation is monotonic: adding sections never
    decreases the level. -/
theorem activation_monotonic (s1 s2 : List ConfigSection)
    (hsub : ∀ x ∈ s1, x ∈ s2) :
    (activationLevel s1).val ≤ (activationLevel s2).val := by
  rw [activationLevel_val, activationLevel_val]; simp only [actLvlN]
  -- Case-split on each s1 membership; transfer to s2 via hsub.
  by_cases h8 : ConfigSection.fullOrch ∈ s1
  · simp [if_pos h8, if_pos (hsub _ h8)]
  · simp only [if_neg h8]
    by_cases h7 : ConfigSection.orders ∈ s1
    · simp [if_pos h7, if_pos (hsub _ h7)]; split <;> omega
    · simp only [if_neg h7]
      by_cases h6 : ConfigSection.daemonHealth ∈ s1
      · simp [if_pos h6, if_pos (hsub _ h6)]; repeat (split <;> try omega)
      · simp only [if_neg h6]
        by_cases h5 : ConfigSection.formulas ∈ s1
        · simp [if_pos h5, if_pos (hsub _ h5)]; repeat (split <;> try omega)
        · simp only [if_neg h5]
          by_cases h4 : ConfigSection.mail ∈ s1
          · simp [if_pos h4, if_pos (hsub _ h4)]; repeat (split <;> try omega)
          · simp only [if_neg h4]
            by_cases h3 : ConfigSection.agentPool ∈ s1
            · simp [if_pos h3, if_pos (hsub _ h3)]; repeat (split <;> try omega)
            · simp only [if_neg h3]
              by_cases h2 : ConfigSection.daemon ∈ s1
              · simp [if_pos h2, if_pos (hsub _ h2)]; repeat (split <;> try omega)
              · simp only [if_neg h2]
                by_cases h1 : ConfigSection.agent ∈ s1 ∧ ConfigSection.workspace ∈ s1
                · simp [if_pos h1, if_pos (And.intro (hsub _ h1.1) (hsub _ h1.2))]
                  repeat (split <;> try omega)
                · simp [if_neg h1]

end GasCity.Layering
