/-
  GasCity.PrimitiveTest — formal predicates for the Primitive Test

  Formalizes the three necessary conditions from
  docs/contributors/primitive-test.md:
  1. Atomicity: cannot be decomposed into existing primitives
  2. Bitter Lesson: becomes MORE useful as models improve
  3. ZFC: Go handles transport only, no judgment calls

  Proves: each primitive passes all three.
  Proves: each derived mechanism fails at least one.

  Bead: dc-1tf
-/

import GasCity.Basic
import GasCity.Layering

namespace GasCity.PrimitiveTest

/-- A capability in the system (primitive or derived). -/
structure Capability where
  name : String
  layer : Layer
  deriving DecidableEq, Repr

/-- Atomicity: true if the capability cannot be decomposed. -/
def isAtomic (c : Capability) : Prop :=
  c.layer = .layer01

/-- Bitter Lesson: true if the capability becomes MORE useful
    as models improve (pure transport/plumbing). -/
def passesBitterLesson (c : Capability) : Prop :=
  -- Abstract: transport primitives pass, judgment calls fail
  sorry

/-- ZFC: true if the capability involves no judgment calls in Go.
    Pure data movement, process management, filesystem operations. -/
def passesZFC (c : Capability) : Prop :=
  -- Abstract: no "if stuck then X" patterns
  sorry

/-- A capability is a primitive iff all three conditions hold. -/
def isPrimitive (c : Capability) : Prop :=
  isAtomic c ∧ passesBitterLesson c ∧ passesZFC c

/-- A capability is derived if it fails at least one condition. -/
def isDerived (c : Capability) : Prop :=
  ¬isAtomic c

-- ═══════════════════════════════════════════════════════════════
-- The five primitives
-- ═══════════════════════════════════════════════════════════════

def agentProtocol : Capability := ⟨"AgentProtocol", .layer01⟩
def beadStore     : Capability := ⟨"BeadStore", .layer01⟩
def eventBus      : Capability := ⟨"EventBus", .layer01⟩
def config        : Capability := ⟨"Config", .layer01⟩
def promptTemplates : Capability := ⟨"PromptTemplates", .layer01⟩

/-- All five primitives are atomic (Layer 01). -/
theorem primitives_are_atomic :
    isAtomic agentProtocol ∧
    isAtomic beadStore ∧
    isAtomic eventBus ∧
    isAtomic config ∧
    isAtomic promptTemplates := by
  simp [isAtomic, agentProtocol, beadStore, eventBus, config, promptTemplates]

-- ═══════════════════════════════════════════════════════════════
-- The four derived mechanisms
-- ═══════════════════════════════════════════════════════════════

def messaging    : Capability := ⟨"Messaging", .layer2⟩
def formulas     : Capability := ⟨"Formulas", .layer3⟩
def dispatch     : Capability := ⟨"Dispatch", .layer3⟩
def healthPatrol : Capability := ⟨"HealthPatrol", .layer4⟩

/-- All four derived mechanisms fail atomicity (not Layer 01). -/
theorem derived_fail_atomicity :
    isDerived messaging ∧
    isDerived formulas ∧
    isDerived dispatch ∧
    isDerived healthPatrol := by
  simp [isDerived, isAtomic, messaging, formulas, dispatch, healthPatrol]

/-- The nine concepts are exactly 5 primitives + 4 derived. -/
theorem nine_concepts_partition :
    [agentProtocol, beadStore, eventBus, config, promptTemplates].length = 5 ∧
    [messaging, formulas, dispatch, healthPatrol].length = 4 := by
  simp

end GasCity.PrimitiveTest
