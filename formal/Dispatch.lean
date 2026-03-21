/-
  Dispatch: Sling operation model — template substitution, bead assignment,
  event recording

  The dispatch (sling) system orchestrates agent work by:
  1. Substituting placeholders in formula templates with concrete values
  2. Creating and assigning work beads to agents
  3. Recording dispatch events for observability

  Properties proved:
    1. substitute — concrete replacement with placeholder removal guarantee
    2. sling_assigns_bead — created bead is assigned to the target agent
    3. sling_records_event — event list grows by at least 1 after sling

  Go source reference: internal/dispatch/dispatch.go
  Architecture: docs/architecture/dispatch.md
-/

import Core

namespace Dispatch

/-! ====================================================================
    IDENTITY TYPES
    ==================================================================== -/

structure BeadId where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

structure AgentId where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

instance : LawfulBEq BeadId where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

instance : LawfulBEq AgentId where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

/-! ====================================================================
    TEMPLATE SUBSTITUTION (Property 1)
    ==================================================================== -/

/-- A template segment: either literal text or a named placeholder. -/
inductive Segment where
  | lit (text : String)
  | placeholder (name : String)
  deriving Repr, DecidableEq, BEq

/-- A template is a sequence of segments. -/
abbrev Template := List Segment

/-- Substitute: replace all placeholders matching the name with a literal
    value. Placeholders with different names are left unchanged. -/
def substitute (tmpl : Template) (name : String) (value : String) : Template :=
  tmpl.map fun s => match s with
    | .placeholder n => if n == name then .lit value else .placeholder n
    | .lit t => .lit t

/-- Render a fully-resolved template to a string. Unresolved placeholders
    render as {name}. -/
def render (tmpl : Template) : String :=
  tmpl.foldl (fun acc s => acc ++ match s with
    | .lit t => t
    | .placeholder n => "{" ++ n ++ "}") ""

/-- Substituting in an empty template gives an empty template. -/
theorem substitute_empty (name : String) (value : String) :
    substitute [] name value = [] := by
  simp [substitute]

/-- A pure literal template is unchanged by substitution. -/
theorem substitute_lit_unchanged (t : String) (name : String) (value : String) :
    substitute [.lit t] name value = [.lit t] := by
  simp [substitute]

/-- Substituting a matching placeholder produces a literal. -/
theorem substitute_placeholder_replaces (name : String) (value : String) :
    substitute [.placeholder name] name value = [.lit value] := by
  simp [substitute]

/-- Substituting a non-matching placeholder leaves it unchanged. -/
theorem substitute_placeholder_preserves (name other : String) (value : String)
    (hne : other ≠ name) :
    substitute [.placeholder other] name value = [.placeholder other] := by
  simp [substitute, hne]

/-- Substitute distributes over concatenation. -/
theorem substitute_append (t1 t2 : Template) (name : String) (value : String) :
    substitute (t1 ++ t2) name value =
    substitute t1 name value ++ substitute t2 name value := by
  simp [substitute, List.map_append]

/-- Substitute length is preserved. -/
theorem substitute_length (tmpl : Template) (name : String) (value : String) :
    (substitute tmpl name value).length = tmpl.length := by
  simp [substitute]

/-- Double substitution with same name is idempotent. -/
theorem substitute_idempotent (tmpl : Template) (name : String) (value : String) :
    substitute (substitute tmpl name value) name value =
    substitute tmpl name value := by
  simp only [substitute, List.map_map]
  congr 1
  funext s
  cases s with
  | lit _ => rfl
  | placeholder n =>
    simp only [Function.comp]
    cases h : (n == name)
    · -- n == name = false: placeholder unchanged, second sub also sees false
      simp [h]
    · -- n == name = true: becomes .lit value, second sub on .lit is identity
      simp

/-! ====================================================================
    DISPATCH STATE
    ==================================================================== -/

/-- A bead (work item) in the dispatch system. -/
structure Bead where
  id : BeadId
  assignee : Option AgentId
  deriving Repr, DecidableEq, BEq

/-- A dispatch event recorded for observability. -/
structure DispatchEvent where
  beadId : BeadId
  agent : AgentId
  deriving Repr

/-- The dispatch state: beads + event log. -/
structure DispatchState where
  beads : List Bead
  events : List DispatchEvent
  deriving Repr

def DispatchState.empty : DispatchState := { beads := [], events := [] }

/-! ====================================================================
    OPERATIONS
    ==================================================================== -/

/-- Create a new unassigned bead. -/
def createBead (s : DispatchState) (id : BeadId) : DispatchState :=
  { s with beads := s.beads ++ [{ id := id, assignee := none }] }

/-- Update assignee for a bead by ID. -/
def updateAssignee (beads : List Bead) (id : BeadId) (agent : AgentId) : List Bead :=
  beads.map fun b => if b.id == id then { b with assignee := some agent } else b

/-- Record a dispatch event. -/
def recordDispatchEvent (s : DispatchState) (evt : DispatchEvent) : DispatchState :=
  { s with events := s.events ++ [evt] }

/-- Sling: create a bead, assign to agent, record dispatch event.
    This is the core dispatch primitive — create → assign → log. -/
def sling (s : DispatchState) (beadId : BeadId) (agent : AgentId) : DispatchState :=
  let s1 := createBead s beadId
  let s2 := { s1 with beads := updateAssignee s1.beads beadId agent }
  recordDispatchEvent s2 { beadId := beadId, agent := agent }

/-! ====================================================================
    PROPERTY 2: SLING ASSIGNS BEAD
    Track assignee through the create → update pipeline.
    ==================================================================== -/

/-- After sling, the created bead exists and is assigned to the target agent. -/
theorem sling_assigns_bead (s : DispatchState) (beadId : BeadId) (agent : AgentId) :
    ∃ b ∈ (sling s beadId agent).beads,
      b.id = beadId ∧ b.assignee = some agent := by
  simp only [sling, recordDispatchEvent, createBead, updateAssignee]
  refine ⟨{ id := beadId, assignee := some agent }, ?_, rfl, rfl⟩
  rw [List.map_append]
  apply List.mem_append.mpr
  right
  simp [List.map]

/-- Sling preserves all existing beads (modulo assignee update). -/
theorem sling_preserves_beads (s : DispatchState) (beadId : BeadId) (agent : AgentId) :
    ∀ b ∈ s.beads, ∃ b' ∈ (sling s beadId agent).beads, b'.id = b.id := by
  intro b hb
  simp only [sling, recordDispatchEvent, createBead, updateAssignee]
  refine ⟨if b.id == beadId then { b with assignee := some agent } else b, ?_, ?_⟩
  · rw [List.map_append]
    apply List.mem_append.mpr
    left
    apply List.mem_map.mpr
    exact ⟨b, hb, rfl⟩
  · split <;> simp

/-! ====================================================================
    PROPERTY 3: SLING RECORDS EVENT
    Show event list grows by at least 1.
    ==================================================================== -/

/-- After sling, the event list grows by exactly 1. -/
theorem sling_records_event (s : DispatchState) (beadId : BeadId) (agent : AgentId) :
    (sling s beadId agent).events.length = s.events.length + 1 := by
  simp [sling, recordDispatchEvent, createBead, updateAssignee, List.length_append]

/-- Corollary: events strictly grow. -/
theorem sling_events_grow (s : DispatchState) (beadId : BeadId) (agent : AgentId) :
    (sling s beadId agent).events.length > s.events.length := by
  have := sling_records_event s beadId agent
  omega

/-- The recorded event references the correct bead and agent. -/
theorem sling_event_correct (s : DispatchState) (beadId : BeadId) (agent : AgentId) :
    ∃ evt ∈ (sling s beadId agent).events,
      evt.beadId = beadId ∧ evt.agent = agent := by
  simp only [sling, recordDispatchEvent, createBead, updateAssignee]
  exact ⟨{ beadId := beadId, agent := agent },
    List.mem_append.mpr (Or.inr (List.Mem.head _)), rfl, rfl⟩

/-- Sling preserves all existing events. -/
theorem sling_preserves_events (s : DispatchState) (beadId : BeadId) (agent : AgentId) :
    ∀ evt ∈ s.events, evt ∈ (sling s beadId agent).events := by
  intro evt hevt
  simp only [sling, recordDispatchEvent, createBead, updateAssignee]
  exact List.mem_append_left _ hevt

/-! ====================================================================
    ADDITIONAL: SLING ON EMPTY STATE
    ==================================================================== -/

/-- Sling on empty state produces exactly one bead and one event. -/
theorem sling_empty_beads (beadId : BeadId) (agent : AgentId) :
    (sling DispatchState.empty beadId agent).beads =
    [{ id := beadId, assignee := some agent }] := by
  simp [sling, recordDispatchEvent, createBead, updateAssignee,
        DispatchState.empty, List.map]

theorem sling_empty_events (beadId : BeadId) (agent : AgentId) :
    (sling DispatchState.empty beadId agent).events =
    [{ beadId := beadId, agent := agent }] := by
  simp [sling, recordDispatchEvent, createBead, updateAssignee,
        DispatchState.empty]

/-! ====================================================================
    VERDICT
    ====================================================================

  PROVEN (zero sorries):

  1. substitute — concrete template replacement
     - substitute_placeholder_replaces: matching placeholder → literal
     - substitute_placeholder_preserves: non-matching placeholder unchanged
     - substitute_idempotent: double substitution = single substitution
     - substitute_append: distributes over concatenation
     - substitute_length: preserves template segment count

  2. sling_assigns_bead
     Created bead is assigned to the target agent after the
     create → update pipeline.

  3. sling_records_event / sling_events_grow
     Event list grows by exactly 1 after sling.

  ADDITIONAL:
  - sling_event_correct: recorded event references correct bead+agent
  - sling_preserves_events: existing events are preserved
  - sling_preserves_beads: existing beads are preserved (IDs intact)
  - sling_empty_*: sling on empty state produces exactly 1 bead + 1 event
-/

end Dispatch
