/-
  GasCity.BeadStore — Primitive 2: CRUD invariants and status machine

  Formalizes beads.Store from internal/beads/beads.go.

  COVERAGE (vs Go implementation):
    Bead fields modeled:    7/13 (missing Title, From, Ref, Needs, Description, Metadata)
    UpdateOpts fields:      3/7  (missing Title, Description, ParentID, RemoveLabels)
    Store methods modeled:  5/14 (missing List, ListByLabel, ListByAssignee, SetMetadata,
                                  SetMetadataBatch, Ping, DepAdd, DepRemove, DepList)
    Helper types:           1/3  (missing Dep struct, ErrNotFound)

  The Lean model captures the core CRUD + label append + status machine.
  Metadata, dependencies, and query methods are not yet formalized.

  Go source: internal/beads/beads.go
  Architecture: docs/architecture/beads.md
  Bead: dc-6xc
-/

import GasCity.Basic

namespace GasCity.BeadStore

/-- A bead record. -/
structure Bead where
  id : BeadId
  status : Status
  type : BeadType
  parentId : Option BeadId
  labels : List Label
  assignee : Option String
  createdAt : Timestamp
  deriving DecidableEq, Repr

/-- Update options. None means "don't change this field." -/
structure UpdateOpts where
  status : Option Status := none
  assignee : Option (Option String) := none
  labels : Option (List Label) := none  -- appended, never replaced

/-- Abstract store state: a partial map from ID to Bead,
    plus a counter for generating unique IDs. -/
structure StoreState where
  beads : BeadId → Option Bead
  nextId : Nat

/-- Create a new bead. Returns the bead with assigned ID and status=open. -/
def create (s : StoreState) (b : Bead) : StoreState × Bead :=
  let id := s!"bead-{s.nextId}"
  let newBead : Bead := {
    id := id
    status := GasCity.Status.open  -- invariant: Create always sets open
    type := b.type  -- Go defaults empty Type to "task"; we require caller to set it
    parentId := b.parentId
    labels := b.labels
    assignee := b.assignee
    createdAt := b.createdAt
  }
  ({ beads := fun n => if n = id then some newBead else s.beads n
   , nextId := s.nextId + 1 }, newBead)

/-- Get a bead by ID. Returns none if not found. -/
def get (s : StoreState) (id : BeadId) : Option Bead :=
  s.beads id

/-- Close a bead. Idempotent: no-op if already closed. -/
def close (s : StoreState) (id : BeadId) : StoreState :=
  match s.beads id with
  | none => s
  | some b =>
    { s with beads := fun n =>
        if n = id then some { b with status := GasCity.Status.closed } else s.beads n }

/-- Update a bead. Labels append, nil fields are no-op. -/
def update (s : StoreState) (id : BeadId) (opts : UpdateOpts) : StoreState :=
  match s.beads id with
  | none => s
  | some b =>
    let b' := { b with
      status := opts.status.getD b.status
      assignee := match opts.assignee with | some a => a | none => b.assignee
      labels := match opts.labels with | some ls => b.labels ++ ls | none => b.labels
    }
    { s with beads := fun n => if n = id then some b' else s.beads n }

/-- Ready returns all open beads. -/
def ready (s : StoreState) (allIds : List BeadId) : List Bead :=
  allIds.filterMap fun id =>
    match s.beads id with
    | some b => if b.status = GasCity.Status.open then some b else none
    | none => none

/-- Children returns beads whose parentId matches. -/
def children (s : StoreState) (parentId : BeadId) (allIds : List BeadId) : List Bead :=
  allIds.filterMap fun id =>
    match s.beads id with
    | some b => if b.parentId = some parentId then some b else none
    | none => none

-- ═══════════════════════════════════════════════════════════════
-- Extensionality lemmas
-- ═══════════════════════════════════════════════════════════════

theorem StoreState.ext {s1 s2 : StoreState}
    (beads_eq : s1.beads = s2.beads) (nextId_eq : s1.nextId = s2.nextId) :
    s1 = s2 := by
  cases s1
  cases s2
  simp_all

-- ═══════════════════════════════════════════════════════════════
-- Conformance Suite Theorems (15 invariants)
-- ═══════════════════════════════════════════════════════════════

/-- C1: Create assigns a unique, non-empty ID. -/
theorem create_unique_id (s : StoreState) (b : Bead) :
    let (_, newBead) := create s b
    newBead.id ≠ "" := by
  simp only [create]
  sorry

/-- C2: Create sets Status = open regardless of input. -/
theorem create_status_open (s : StoreState) (b : Bead) :
    let (_, newBead) := create s b
    newBead.status = GasCity.Status.open := by
  simp [create]

/-- C3: Two sequential creates produce different IDs. -/
theorem create_ids_differ (s : StoreState) (b1 b2 : Bead) :
    let (s', bead1) := create s b1
    let (_, bead2) := create s' b2
    bead1.id ≠ bead2.id := by
  simp only [create]
  sorry

/-- C6: Close is idempotent. -/
theorem close_idempotent (s : StoreState) (id : BeadId) :
    close (close s id) id = close s id := by
  simp only [close]
  cases h : s.beads id with
  | none => simp [h]
  | some b =>
    simp only [h]
    apply StoreState.ext
    · funext n
      by_cases hn : n = id
      · subst hn; simp
      · simp [hn]
    · rfl

/-- C7: Close removes from Ready.
    NOTE: Requires well-formedness: s.beads id' = some b → b.id = id'.
    Without this invariant, b.id ≠ id cannot be proved from the store alone
    (the beads field is an abstract function with no injectivity guarantee).
    The invariant is established by construction (create always sets b.id to the key),
    but tracking it through the store would require a separate invariant theorem. -/
theorem close_removes_from_ready (s : StoreState) (id : BeadId) (allIds : List BeadId)
    (h : id ∈ allIds)
    (hwf : ∀ id' b, s.beads id' = some b → b.id = id') :
    ∀ b ∈ ready (close s id) allIds, b.id ≠ id := by
  sorry -- proof needs: b came from id' ≠ id → b.id = id' (hwf) → b.id ≠ id

/-- C8: Update with all-none opts is no-op. -/
theorem update_nil_noop (s : StoreState) (id : BeadId) :
    update s id {} = s := by
  simp only [update]
  cases h : s.beads id with
  | none => rfl
  | some b =>
    simp only [h]
    apply StoreState.ext
    · funext n
      by_cases hn : n = id
      · subst hn; simp [h]
      · simp [hn]
    · rfl

/-- C9: Labels only append, never replace. -/
theorem labels_append (s : StoreState) (id : BeadId) (newLabels : List Label)
    (b : Bead) (hget : s.beads id = some b) :
    let s' := update s id { labels := some newLabels }
    match s'.beads id with
    | some b' => b.labels ++ newLabels = b'.labels
    | none => False := by
  simp only [update, hget]
  simp

end GasCity.BeadStore
