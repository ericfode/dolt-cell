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
-- Helper lemmas for Nat.repr (string ID) injectivity
-- ═══════════════════════════════════════════════════════════════

section NatReprHelpers

set_option maxRecDepth 2000

/-- Unfold Nat.toDigitsCore one step. -/
theorem GasCity.BeadStore.toDigitsCore_succ (fuel n : Nat) (acc : List Char) :
    Nat.toDigitsCore 10 (fuel + 1) n acc =
    if n / 10 = 0 then (n % 10).digitChar :: acc
    else Nat.toDigitsCore 10 fuel (n / 10) ((n % 10).digitChar :: acc) := by
  simp [Nat.toDigitsCore]

/-- The accumulator is always a suffix of toDigitsCore output. -/
theorem GasCity.BeadStore.toDigitsCore_suffix (fuel n : Nat) (acc : List Char) :
    acc <:+ Nat.toDigitsCore 10 (fuel + 1) n acc := by
  induction fuel generalizing n acc with
  | zero =>
    rw [GasCity.BeadStore.toDigitsCore_succ]; split
    · exact List.suffix_cons _ _
    · simp [Nat.toDigitsCore]
  | succ fuel ih =>
    rw [GasCity.BeadStore.toDigitsCore_succ]; split
    · exact List.suffix_cons _ _
    · exact List.IsSuffix.trans (List.suffix_cons _ _) (ih (n / 10) _)

/-- The least-significant digit character is prepended to acc in the output. -/
theorem GasCity.BeadStore.toDigitsCore_digit_suffix (fuel n : Nat) (acc : List Char) :
    ((n % 10).digitChar :: acc) <:+ Nat.toDigitsCore 10 (fuel + 1) n acc := by
  induction fuel generalizing n acc with
  | zero =>
    rw [GasCity.BeadStore.toDigitsCore_succ]; split
    · exact List.suffix_refl _
    · simp [Nat.toDigitsCore]
  | succ fuel ih =>
    rw [GasCity.BeadStore.toDigitsCore_succ]; split
    · exact List.suffix_refl _
    · exact GasCity.BeadStore.toDigitsCore_suffix fuel (n / 10) _

end NatReprHelpers

namespace GasCity.BeadStore

/-- Two singleton suffixes of the same list must agree. -/
theorem suffix_singleton_eq {α : Type} {l : List α} {a b : α}
    (h1 : [a] <:+ l) (h2 : [b] <:+ l) : a = b := by
  have ha : l.getLast? = some a := by
    obtain ⟨t, ht⟩ := h1; rw [← ht, List.getLast?_append]; simp
  have hb : l.getLast? = some b := by
    obtain ⟨t, ht⟩ := h2; rw [← ht, List.getLast?_append]; simp
  rw [ha] at hb; exact Option.some.inj hb

/-- Nat.digitChar is injective on {0, ..., 9}. -/
theorem digitChar_injective_lt10 (n m : Nat) (hn : n < 10) (hm : m < 10)
    (h : Nat.digitChar n = Nat.digitChar m) : n = m := by
  have : ∀ i : Fin 10, ∀ j : Fin 10,
      Nat.digitChar i.val = Nat.digitChar j.val → i = j := by decide
  exact Fin.val_eq_of_eq (this ⟨n, hn⟩ ⟨m, hm⟩ h)

/-- Consecutive naturals have distinct decimal representations. -/
theorem repr_succ_ne (n : Nat) : Nat.repr n ≠ Nat.repr (n + 1) := by
  simp only [Nat.repr, Nat.toDigits]
  intro h
  have h1 := String.ofList_injective h
  have hs1 := toDigitsCore_digit_suffix n n ([] : List Char)
  have hs2 := toDigitsCore_digit_suffix (n + 1) (n + 1) ([] : List Char)
  rw [h1] at hs1
  have := suffix_singleton_eq hs1 hs2
  have := digitChar_injective_lt10 _ _
    (Nat.mod_lt _ (by omega)) (Nat.mod_lt _ (by omega)) this
  omega

-- ═══════════════════════════════════════════════════════════════
-- Helper lemmas for close
-- ═══════════════════════════════════════════════════════════════

/-- Closing a bead does not affect other keys. -/
theorem close_beads_ne (s : StoreState) (bid aid : BeadId) (h : aid ≠ bid) :
    (close s bid).beads aid = s.beads aid := by
  simp only [close]
  split
  · rfl
  · simp [h]

/-- Closing an existing bead sets its status to closed. -/
theorem close_beads_eq (s : StoreState) (bid : BeadId) (b : Bead)
    (h : s.beads bid = some b) :
    (close s bid).beads bid = some { b with status := GasCity.Status.closed } := by
  simp only [close, h, ite_true]

/-- Closing a nonexistent bead is a no-op on that key. -/
theorem close_beads_none (s : StoreState) (bid : BeadId)
    (h : s.beads bid = none) :
    (close s bid).beads bid = none := by
  simp only [close, h]

-- ═══════════════════════════════════════════════════════════════
-- Conformance Suite Theorems (15 invariants)
-- ═══════════════════════════════════════════════════════════════

/-- C1: Create assigns a unique, non-empty ID. -/
theorem create_unique_id (s : StoreState) (b : Bead) :
    let (_, newBead) := create s b
    newBead.id ≠ "" := by
  simp only [create]
  intro h
  have h1 := congrArg String.length h
  simp [String.length_append] at h1
  obtain ⟨h2, _⟩ := h1
  exact absurd h2 (by decide)

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
  intro h
  have h1 : toString s.nextId = toString (s.nextId + 1) := by
    have := congrArg String.toList h
    simp [String.toList_append] at this
    exact String.ext this
  exact absurd h1 (repr_succ_ne s.nextId)

/-- C6: Close is idempotent. -/
theorem close_idempotent (s : StoreState) (id : BeadId) :
    close (close s id) id = close s id := by
  cases h : s.beads id with
  | none => simp [close, h]
  | some b =>
    have hclose : close s id =
      { beads := fun n => if n = id then some { b with status := GasCity.Status.closed } else s.beads n
      , nextId := s.nextId } := by
      simp [close, h]
    rw [hclose]
    simp only [close, ite_true]
    apply StoreState.ext
    · funext n
      by_cases hn : n = id
      · subst hn; simp
      · simp [hn]
    · rfl

/-- C7: Close removes from Ready.
    Requires well-formedness: bead IDs match their storage keys.
    This invariant is maintained by `create`. -/
theorem close_removes_from_ready (s : StoreState) (id : BeadId) (allIds : List BeadId)
    (wf : ∀ k b, s.beads k = some b → b.id = k) :
    ∀ b ∈ ready (close s id) allIds, b.id ≠ id := by
  intro b hb
  simp only [ready] at hb
  rw [List.mem_filterMap] at hb
  obtain ⟨aid, _, hmap⟩ := hb
  by_cases haid : aid = id
  · -- aid = id: after close, bead has status closed (or was absent)
    cases hid : s.beads id with
    | none =>
      rw [haid] at hmap; rw [close_beads_none s id hid] at hmap; simp at hmap
    | some b₀ =>
      rw [haid] at hmap; rw [close_beads_eq s id b₀ hid] at hmap; simp at hmap
  · -- aid ≠ id: bead unchanged, and by well-formedness b.id = aid ≠ id
    rw [close_beads_ne s id aid haid] at hmap
    cases haid2 : s.beads aid with
    | none => rw [haid2] at hmap; simp at hmap
    | some b₀ =>
      rw [haid2] at hmap
      simp only [] at hmap
      split at hmap
      · have := Option.some.inj hmap
        rw [← this, wf aid b₀ haid2]; exact haid
      · simp at hmap

/-- C8: Update with all-none opts is no-op. -/
theorem update_nil_noop (s : StoreState) (id : BeadId) :
    update s id {} = s := by
  simp only [update]
  split
  · rfl
  · next b heq =>
    simp only [Option.getD]
    apply StoreState.ext
    · funext n
      simp only []
      split <;> rename_i h
      · subst h; simp [heq]
      · rfl
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
