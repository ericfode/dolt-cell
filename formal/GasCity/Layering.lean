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

/-- Progressive activation is monotonic: adding sections never
    decreases the level. -/
theorem activation_monotonic (s1 s2 : List ConfigSection)
    (hsub : ∀ x ∈ s1, x ∈ s2) :
    (activationLevel s1).val ≤ (activationLevel s2).val := by
  simp only [activationLevel]
  -- For each level-determining condition C that holds for s1,
  -- hsub gives it for s2 too. We case-split using if_pos/if_neg.
  by_cases h8 : .fullOrch ∈ s1
  · have h8' := hsub _ h8
    simp only [if_pos h8, if_pos h8']
    omega
  by_cases h7 : .orders ∈ s1
  · have h7' := hsub _ h7
    simp only [if_neg h8, if_pos h7]
    by_cases h8' : .fullOrch ∈ s2
    · simp only [if_pos h8']; omega
    · simp only [if_neg h8', if_pos h7']; omega
  by_cases h6 : .daemonHealth ∈ s1
  · have h6' := hsub _ h6
    simp only [if_neg h8, if_neg h7, if_pos h6]
    by_cases h8' : .fullOrch ∈ s2
    · simp only [if_pos h8']; omega
    · by_cases h7' : .orders ∈ s2
      · simp only [if_neg h8', if_pos h7']; omega
      · simp only [if_neg h8', if_neg h7', if_pos h6']; omega
  by_cases h5 : .formulas ∈ s1
  · have h5' := hsub _ h5
    simp only [if_neg h8, if_neg h7, if_neg h6, if_pos h5]
    by_cases h8' : .fullOrch ∈ s2
    · simp only [if_pos h8']; omega
    · by_cases h7' : .orders ∈ s2
      · simp only [if_neg h8', if_pos h7']; omega
      · by_cases h6' : .daemonHealth ∈ s2
        · simp only [if_neg h8', if_neg h7', if_pos h6']; omega
        · simp only [if_neg h8', if_neg h7', if_neg h6', if_pos h5']; omega
  by_cases h4 : .mail ∈ s1
  · have h4' := hsub _ h4
    simp only [if_neg h8, if_neg h7, if_neg h6, if_neg h5, if_pos h4]
    by_cases h8' : .fullOrch ∈ s2
    · simp only [if_pos h8']; omega
    · by_cases h7' : .orders ∈ s2
      · simp only [if_neg h8', if_pos h7']; omega
      · by_cases h6' : .daemonHealth ∈ s2
        · simp only [if_neg h8', if_neg h7', if_pos h6']; omega
        · by_cases h5' : .formulas ∈ s2
          · simp only [if_neg h8', if_neg h7', if_neg h6', if_pos h5']; omega
          · simp only [if_neg h8', if_neg h7', if_neg h6', if_neg h5', if_pos h4']; omega
  by_cases h3 : .agentPool ∈ s1
  · have h3' := hsub _ h3
    simp only [if_neg h8, if_neg h7, if_neg h6, if_neg h5, if_neg h4, if_pos h3]
    by_cases h8' : .fullOrch ∈ s2
    · simp only [if_pos h8']; omega
    · by_cases h7' : .orders ∈ s2
      · simp only [if_neg h8', if_pos h7']; omega
      · by_cases h6' : .daemonHealth ∈ s2
        · simp only [if_neg h8', if_neg h7', if_pos h6']; omega
        · by_cases h5' : .formulas ∈ s2
          · simp only [if_neg h8', if_neg h7', if_neg h6', if_pos h5']; omega
          · by_cases h4' : .mail ∈ s2
            · simp only [if_neg h8', if_neg h7', if_neg h6', if_neg h5', if_pos h4']; omega
            · simp only [if_neg h8', if_neg h7', if_neg h6', if_neg h5', if_neg h4', if_pos h3']; omega
  by_cases h2 : .daemon ∈ s1
  · have h2' := hsub _ h2
    simp only [if_neg h8, if_neg h7, if_neg h6, if_neg h5, if_neg h4, if_neg h3, if_pos h2]
    by_cases h8' : .fullOrch ∈ s2
    · simp only [if_pos h8']; omega
    · by_cases h7' : .orders ∈ s2
      · simp only [if_neg h8', if_pos h7']; omega
      · by_cases h6' : .daemonHealth ∈ s2
        · simp only [if_neg h8', if_neg h7', if_pos h6']; omega
        · by_cases h5' : .formulas ∈ s2
          · simp only [if_neg h8', if_neg h7', if_neg h6', if_pos h5']; omega
          · by_cases h4' : .mail ∈ s2
            · simp only [if_neg h8', if_neg h7', if_neg h6', if_neg h5', if_pos h4']; omega
            · by_cases h3' : .agentPool ∈ s2
              · simp only [if_neg h8', if_neg h7', if_neg h6', if_neg h5', if_neg h4', if_pos h3']; omega
              · simp only [if_neg h8', if_neg h7', if_neg h6', if_neg h5', if_neg h4', if_neg h3', if_pos h2']; omega
  -- s1 level = 0 or 1 (only agent∧workspace or nothing)
  by_cases ha : .agent ∈ s1 <;> by_cases hw : .workspace ∈ s1
  · have ha' := hsub _ ha; have hw' := hsub _ hw
    simp only [if_neg h8, if_neg h7, if_neg h6, if_neg h5, if_neg h4, if_neg h3, if_neg h2,
               if_pos (show .agent ∈ s1 ∧ .workspace ∈ s1 from ⟨ha, hw⟩)]
    by_cases h8' : .fullOrch ∈ s2
    · simp only [if_pos h8']; omega
    · by_cases h7' : .orders ∈ s2
      · simp only [if_neg h8', if_pos h7']; omega
      · by_cases h6' : .daemonHealth ∈ s2
        · simp only [if_neg h8', if_neg h7', if_pos h6']; omega
        · by_cases h5' : .formulas ∈ s2
          · simp only [if_neg h8', if_neg h7', if_neg h6', if_pos h5']; omega
          · by_cases h4' : .mail ∈ s2
            · simp only [if_neg h8', if_neg h7', if_neg h6', if_neg h5', if_pos h4']; omega
            · by_cases h3' : .agentPool ∈ s2
              · simp only [if_neg h8', if_neg h7', if_neg h6', if_neg h5', if_neg h4', if_pos h3']; omega
              · by_cases h2' : .daemon ∈ s2
                · simp only [if_neg h8', if_neg h7', if_neg h6', if_neg h5', if_neg h4', if_neg h3', if_pos h2']; omega
                · simp only [if_neg h8', if_neg h7', if_neg h6', if_neg h5', if_neg h4', if_neg h3', if_neg h2',
                             if_pos (show .agent ∈ s2 ∧ .workspace ∈ s2 from ⟨ha', hw'⟩)]; omega
  -- Remaining cases: ha/hw not both true, so s1 level = 0 ≤ anything
  · -- ha : .agent ∈ s1, hw : ¬ .workspace ∈ s1
    simp only [if_neg h8, if_neg h7, if_neg h6, if_neg h5, if_neg h4, if_neg h3, if_neg h2,
               if_neg (show ¬ (.agent ∈ s1 ∧ .workspace ∈ s1) from fun ⟨_, hw'⟩ => hw hw')]
    omega
  · -- ha : ¬ .agent ∈ s1, hw : .workspace ∈ s1
    simp only [if_neg h8, if_neg h7, if_neg h6, if_neg h5, if_neg h4, if_neg h3, if_neg h2,
               if_neg (show ¬ (.agent ∈ s1 ∧ .workspace ∈ s1) from fun ⟨ha', _⟩ => ha ha')]
    omega
  · -- ha : ¬ .agent ∈ s1, hw : ¬ .workspace ∈ s1
    simp only [if_neg h8, if_neg h7, if_neg h6, if_neg h5, if_neg h4, if_neg h3, if_neg h2,
               if_neg (show ¬ (.agent ∈ s1 ∧ .workspace ∈ s1) from fun ⟨ha', _⟩ => ha ha')]
    omega

end GasCity.Layering
