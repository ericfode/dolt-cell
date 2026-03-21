/-
  GasCity.Dispatch — Derived Mechanism 8: sling composition proof

  Models the core sling pipeline: route a bead to an agent.

  DERIVATION CLAIM (from nine-concepts.md):
    Dispatch = AgentProtocol + Config + BeadStore + EventBus.
  ACTUAL Go IMPLEMENTATION (cmd_sling.go doSling, 200+ lines):
    The claim is aspirational. The real sling also depends on:
    - Formula compilation + molecule instantiation (not a primitive)
    - Shell command execution via sling_query (I/O side effect)
    - Socket poke to controller (I/O side effect)
    - Pre-flight idempotency gate (beadStore query)
    - Batch/container expansion (doSlingBatch iterates children)
    - Merge strategy metadata mutations
    The Lean model captures the CRUD core but not the full pipeline.

  Architecture: docs/architecture/dispatch.md
  Bead: dc-5lj
-/

import GasCity.AgentProtocol
import GasCity.BeadStore
import GasCity.EventBus
import GasCity.Config

namespace GasCity.Dispatch

/-- Sling options for routing a bead. -/
structure SlingOpts where
  target : SessionName
  beadId : BeadId
  formula : Option String := none
  nudge : Bool := false
  convoy : Bool := true

/-- Placeholder substitution: replace {} with bead ID. -/
opaque substitute (template : String) (beadId : BeadId) : String

/-- Route a bead: the core sling pipeline.
    Returns updated states for all four substrates. -/
def sling (ps : AgentProtocol.ProviderState)
          (bs : BeadStore.StoreState)
          (el : EventBus.EventLog)
          (opts : SlingOpts) (ts : Timestamp) :
    AgentProtocol.ProviderState × BeadStore.StoreState × EventBus.EventLog :=
  -- Step 1: Check agent is running (P1)
  let _agentRunning := match ps.sessions opts.target with
    | .running _ => true
    | .notRunning => false
  -- Step 2: Update bead assignment (P2)
  let bs' := BeadStore.update bs opts.beadId {
    assignee := some (some opts.target)
    status := some .in_progress
  }
  -- Step 3: Create convoy if needed (P2)
  let (bs'', _convoyId) := if opts.convoy then
    let (s, convoy) := BeadStore.create bs' {
      id := ""
      status := .open
      type := .convoy
      parentId := none
      labels := []
      assignee := some opts.target
      createdAt := ts
    }
    (s, some convoy.id)
  else (bs', none)
  -- Step 4: Log event (P3)
  let el' := EventBus.record el {
    seq := 0  -- assigned by EventBus
    type := "bead.slung"
    ts := ts
    actor := "controller"
    subject := opts.beadId
    message := s!"Slung to {opts.target}"
  }
  (ps, bs'', el')

-- ═══════════════════════════════════════════════════════════════
-- Theorems
-- ═══════════════════════════════════════════════════════════════

/-- Sling updates the bead's assignee. -/
theorem sling_assigns_bead (ps : AgentProtocol.ProviderState)
    (bs : BeadStore.StoreState) (el : EventBus.EventLog)
    (opts : SlingOpts) (ts : Timestamp)
    (b : BeadStore.Bead) (hget : bs.beads opts.beadId = some b) :
    let (_, bs', _) := sling ps bs el opts ts
    match bs'.beads opts.beadId with
    | some b' => b'.assignee = some opts.target
    | none => False := by
  sorry -- needs tracking through update + create

/-- Sling records an event. -/
theorem sling_records_event (ps : AgentProtocol.ProviderState)
    (bs : BeadStore.StoreState) (el : EventBus.EventLog)
    (opts : SlingOpts) (ts : Timestamp) :
    let (_, _, el') := sling ps bs el opts ts
    el'.events.length > el.events.length := by
  sorry

-- TODO: formalize derivation claim as a real theorem
/-- Derivation claim: the CRUD core of sling uses P1, P2, P3, P4.
    NOTE: The full Go sling pipeline also depends on formula compilation,
    shell execution (sling_query), and controller socket I/O — these are
    NOT modeled here. This theorem covers only the idealized CRUD path. -/
theorem derivation_crud_core :
    -- The modeled sling function calls only:
    --   AgentProtocol: sessions lookup (P1)
    --   BeadStore: update + create (P2)
    --   EventBus: record (P3)
    --   Config: formula selection (P4, implicit in SlingOpts)
    True := by trivial

end GasCity.Dispatch
