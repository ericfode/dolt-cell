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
-- String helpers for ID uniqueness proofs
-- ═══════════════════════════════════════════════════════════════

private theorem Nat.toDigitsCore_append (base fuel n : Nat) (ds : List Char) :
    Nat.toDigitsCore base fuel n ds = Nat.toDigitsCore base fuel n [] ++ ds := by
  induction fuel generalizing n ds with
  | zero => simp [Nat.toDigitsCore]
  | succ fuel ih =>
    simp only [Nat.toDigitsCore]; split
    · simp
    · rw [ih, ih (ds := [_])]; simp [List.append_assoc, List.cons_append]

private theorem Nat.toDigitsCore_getLast? (base fuel n : Nat) :
    List.getLast? (Nat.toDigitsCore base (fuel + 1) n [])
      = some (Nat.digitChar (n % base)) := by
  simp only [Nat.toDigitsCore]; split
  · simp [List.getLast?]
  · rw [Nat.toDigitsCore_append]; exact List.getLast?_concat ..

private theorem Nat.repr_ne_succ (n : Nat) : Nat.repr n ≠ Nat.repr (n + 1) := by
  intro h; unfold Nat.repr at h
  have h1 : Nat.toDigits 10 n = Nat.toDigits 10 (n + 1) := by
    have := congrArg String.toList h; simp [String.toList_ofList] at this; exact this
  unfold Nat.toDigits at h1
  have ln := Nat.toDigitsCore_getLast? 10 n n
  rw [h1, Nat.toDigitsCore_getLast? 10 (n + 1) (n + 1)] at ln
  have hinj := Option.some.inj ln
  have h_dc : ∀ k, k < 10 → (Nat.digitChar k).toNat = 48 + k := by
    intro k hk; rcases k with _ | _ | _ | _ | _ | _ | _ | _ | _ | _ | k
    all_goals (first | rfl | omega)
  have := congrArg Char.toNat hinj
  have := h_dc _ (Nat.mod_lt n (by omega))
  have := h_dc _ (Nat.mod_lt (n + 1) (by omega))
  omega

-- ═══════════════════════════════════════════════════════════════
-- Conformance Suite Theorems (15 invariants)
-- ═══════════════════════════════════════════════════════════════

/-- C1: Create assigns a unique, non-empty ID. -/
theorem create_unique_id (s : StoreState) (b : Bead) :
    let (_, newBead) := create s b
    newBead.id ≠ "" := by
  simp only [create, toString]
  intro h
  have : ("bead-" ++ Nat.repr s.nextId).length = ("").length := congrArg String.length h
  simp (config := { decide := true }) [String.length_append] at this

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
  simp only [create, toString]
  intro h
  have := congrArg String.toList h
  simp [String.toList_append] at this
  exact absurd (String.ext this) (Nat.repr_ne_succ s.nextId)

/-- C6: Close is idempotent. -/
theorem close_idempotent (s : StoreState) (id : BeadId) :
    close (close s id) id = close s id := by
  rcases hs : s.beads id with _ | b
  · simp [close, hs]
  · have hclose : close s id =
        { beads := fun n => if n = id then some { b with status := Status.closed }
            else s.beads n, nextId := s.nextId } := by
      unfold close; simp [hs]
    rw [hclose]; unfold close; simp
    funext n; split <;> rfl

/-- C7: Close removes from Ready.
    Requires store consistency: beads are stored at their own ID key. -/
theorem close_removes_from_ready (s : StoreState) (id : BeadId) (allIds : List BeadId)
    (_ : id ∈ allIds)
    (hc : ∀ aid b, s.beads aid = some b → b.id = aid) :
    ∀ b ∈ ready (close s id) allIds, b.id ≠ id := by
  intro b hb; simp only [ready, List.mem_filterMap] at hb
  obtain ⟨aid, _, haid_eq⟩ := hb
  rcases hs_id : s.beads id with _ | ob
  · -- close is no-op
    rw [show close s id = s by unfold close; simp [hs_id]] at haid_eq
    rcases hs_aid : s.beads aid with _ | b' <;> simp [hs_aid] at haid_eq
    obtain ⟨_, rfl⟩ := haid_eq
    intro heq; have : aid = id := (hc _ _ hs_aid).symm.trans heq
    rw [this] at hs_aid; rw [hs_aid] at hs_id; exact absurd hs_id (by simp)
  · -- close sets status to closed
    have hcb : (close s id).beads = fun n =>
        if n = id then some { ob with status := Status.closed } else s.beads n := by
      unfold close; simp [hs_id]
    by_cases haid_id : aid = id
    · subst haid_id; simp [hcb] at haid_eq
    · simp [hcb, haid_id] at haid_eq
      rcases hs_aid : s.beads aid with _ | b' <;> simp [hs_aid] at haid_eq
      obtain ⟨_, rfl⟩ := haid_eq
      exact fun heq => haid_id ((hc _ _ hs_aid).symm.trans heq)

/-- C8: Update with all-none opts is no-op. -/
theorem update_nil_noop (s : StoreState) (id : BeadId) :
    update s id {} = s := by
  unfold update; split
  · rfl
  · rename_i b hb; simp only [Option.getD]; congr 1; funext n
    split <;> simp_all

/-- C9: Labels only append, never replace. -/
theorem labels_append (s : StoreState) (id : BeadId) (newLabels : List Label)
    (b : Bead) (hget : s.beads id = some b) :
    let s' := update s id { labels := some newLabels }
    match s'.beads id with
    | some b' => b.labels ++ newLabels = b'.labels
    | none => False := by
  simp only [update, hget, Option.getD]
  simp

end GasCity.BeadStore
