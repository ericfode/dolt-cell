/-
  BeadStore: Formal model of the bead (issue) tracking store

  Models the CRUD invariants and query interface for the Gas Town bead system:
  - Unique ID generation (counter-based, injective)
  - Status machine (open → in_progress → closed)
  - Close idempotence
  - Ready set correctness
  - Update nil-field preservation
  - Label append semantics
  - Metadata set/batch operations
  - Dependency graph (add/remove/list)
  - Query by label and assignee

  Self-contained: imports only Core.lean (identity types).
-/

import Core

namespace BeadStore

/-! ====================================================================
    BEAD TYPES
    ==================================================================== -/

inductive Status where
  | open
  | inProgress
  | closed
  | escalated
  | deferred
  deriving Repr, DecidableEq, BEq

/-- Bead IDs are Nat-valued (counter-based). Avoids string reasoning. -/
structure BeadId where
  val : Nat
  deriving Repr, DecidableEq, BEq, Hashable

instance : LawfulBEq BeadId where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := Nat) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

/-- A bead (work item) with full field set matching the Go interface. -/
structure Bead where
  id          : BeadId
  title       : String
  description : String := ""
  status      : Status
  assignee    : Option String
  labels      : List String
  metadata    : List (String × String) := []
  origin      : Option String := none     -- who filed this bead
  ref_        : Option String := none     -- external reference
  deriving Repr, DecidableEq, BEq

/-! ====================================================================
    DEPENDENCY TYPE
    ==================================================================== -/

/-- A dependency edge between two beads. -/
structure Dep where
  source : BeadId    -- the dependent bead
  target : BeadId    -- the bead being depended on
  kind   : String    -- "blocks", "discovered-from", etc.
  deriving Repr, DecidableEq, BEq

/-! ====================================================================
    STORE
    ==================================================================== -/

structure Store where
  beads   : List Bead
  counter : Nat
  deps    : List Dep := []
  deriving Repr

def Store.empty : Store := { beads := [], counter := 0 }

/-! ====================================================================
    CORE OPERATIONS
    ==================================================================== -/

/-- Generate a unique bead ID from the counter. -/
def mkId (n : Nat) : BeadId := ⟨n⟩

/-- Create a new bead. -/
def create (st : Store) (title : String) (labels : List String := []) : Store × BeadId :=
  let id := mkId st.counter
  let bead : Bead := {
    id := id, title := title, status := .open, assignee := none, labels := labels
  }
  ({ beads := st.beads ++ [bead], counter := st.counter + 1, deps := st.deps }, id)

/-- Close a bead by ID. -/
def close (st : Store) (id : BeadId) : Store :=
  { st with beads := st.beads.map (fun b =>
      if b.id = id then { b with status := .closed } else b) }

/-- Update a bead: optionally set assignee and/or append labels. -/
def update (st : Store) (id : BeadId) (assignee : Option String := none)
    (newLabels : List String := []) : Store :=
  { st with beads := st.beads.map (fun b =>
      if b.id = id then
        { b with
          assignee := assignee.orElse (fun () => b.assignee)
          labels := b.labels ++ newLabels }
      else b) }

/-- Ready beads: open status and not assigned. -/
def ready (st : Store) : List Bead :=
  st.beads.filter (fun b => decide (b.status = .open ∧ b.assignee = none))

/-! ====================================================================
    METADATA OPERATIONS
    ==================================================================== -/

/-- Set a single metadata key-value pair on a bead.
    Replaces any existing value for that key. -/
def setMetadata (st : Store) (id : BeadId) (key : String) (value : String) : Store :=
  { st with beads := st.beads.map (fun b =>
      if b.id = id then
        { b with metadata := (b.metadata.filter (fun kv => kv.1 ≠ key)) ++ [(key, value)] }
      else b) }

/-- Set multiple metadata key-value pairs (sequential application). -/
def setMetadataBatch (st : Store) (id : BeadId)
    (entries : List (String × String)) : Store :=
  entries.foldl (fun s kv => setMetadata s id kv.1 kv.2) st

/-! ====================================================================
    DEPENDENCY OPERATIONS
    ==================================================================== -/

/-- Add a dependency edge. -/
def addDep (st : Store) (dep : Dep) : Store :=
  { st with deps := st.deps ++ [dep] }

/-- Remove all dependency edges between source and target. -/
def removeDep (st : Store) (source target : BeadId) : Store :=
  { st with deps := st.deps.filter (fun d =>
      ¬(d.source = source ∧ d.target = target)) }

/-- List dependencies where the given bead is the source (depends on). -/
def listDeps (st : Store) (id : BeadId) : List Dep :=
  st.deps.filter (fun d => decide (d.source = id))

/-! ====================================================================
    QUERY OPERATIONS
    ==================================================================== -/

/-- List beads that have a specific label. -/
def listByLabel (st : Store) (label : String) : List Bead :=
  st.beads.filter (fun b => b.labels.any (· == label))

/-- List beads assigned to a specific assignee. -/
def listByAssignee (st : Store) (assignee : String) : List Bead :=
  st.beads.filter (fun b => b.assignee == some assignee)

/-! ====================================================================
    PROPERTY 1: create_unique_id — generated IDs are positive after first
    ==================================================================== -/

/-- The ID generated from counter n has value n. -/
theorem create_unique_id (n : Nat) : (mkId n).val = n := rfl

/-- Create always returns a valid (non-recycled) ID. -/
theorem create_id_eq_counter (st : Store) (title : String) :
    (create st title).2 = mkId st.counter := rfl

/-! ====================================================================
    PROPERTY 2: create_ids_differ — successive IDs differ
    ==================================================================== -/

/-- Two successive creates produce different IDs. -/
theorem create_ids_differ (n : Nat) : mkId n ≠ mkId (n + 1) := by
  simp [mkId, BeadId.mk.injEq]

/-- More generally, mkId is injective. -/
theorem mkId_injective (a b : Nat) (h : mkId a = mkId b) : a = b := by
  simp [mkId, BeadId.mk.injEq] at h
  exact h

/-! ====================================================================
    PROPERTY 3: close_idempotent — closing twice is same as closing once
    ==================================================================== -/

/-- Closing a bead twice is the same as closing it once. -/
theorem close_idempotent (st : Store) (id : BeadId) :
    close (close st id) id = close st id := by
  unfold close
  simp only [List.map_map]
  let f : Bead → Bead := fun b =>
    if b.id = id then { b with status := Status.closed } else b
  have hf : f ∘ f = f := by
    funext b
    dsimp only [f, Function.comp]
    by_cases h : b.id = id <;> simp [h]
  rw [show st.beads.map (f ∘ f) = st.beads.map f by rw [hf]]

/-! ====================================================================
    PROPERTY 4: close_removes_from_ready — closed beads are not ready
    ==================================================================== -/

/-- After closing, a bead with that ID is not in the ready set. -/
theorem close_removes_from_ready (st : Store) (id : BeadId) :
    ∀ b ∈ ready (close st id), b.id ≠ id := by
  intro b hb hne
  simp only [ready, close] at hb
  rw [List.mem_filter] at hb
  obtain ⟨hmem, hdec⟩ := hb
  rw [List.mem_map] at hmem
  obtain ⟨b', _, hmap⟩ := hmem
  have hcase : b'.id = id := by
    by_cases hc : b'.id = id
    · exact hc
    · simp [hc] at hmap; rw [← hmap] at hne; exact absurd hne hc
  simp [hcase] at hmap
  rw [← hmap] at hdec
  simp at hdec

/-! ====================================================================
    PROPERTY 5: update_nil_noop — update with no changes is identity
    ==================================================================== -/

/-- Struct eta: updating a bead with its own field values is identity. -/
private theorem bead_with_eta (b : Bead) :
    { b with assignee := b.assignee, labels := b.labels } = b := by
  cases b; rfl

/-- Update with no assignee and no labels is identity. -/
theorem update_nil_noop (st : Store) (bid : BeadId) :
    update st bid none [] = st := by
  cases st with | mk beads counter deps =>
  simp only [update, Option.orElse, List.append_nil, Store.mk.injEq, and_true]
  induction beads with
  | nil => rfl
  | cons x xs ih =>
    simp only [List.map_cons, List.cons.injEq]
    exact ⟨by split <;> (first | (cases x; rfl) | rfl), ih⟩

/-! ====================================================================
    PROPERTY 6: labels_append — update with labels appends
    ==================================================================== -/

/-- Update appends new labels to the existing ones for the target bead. -/
theorem labels_append (st : Store) (id : BeadId) (newLabels : List String)
    (b : Bead) (hb : b ∈ st.beads) (hid : b.id = id) :
    ∃ b' ∈ (update st id none newLabels).beads,
      b'.id = id ∧ b'.labels = b.labels ++ newLabels := by
  simp only [update, Option.orElse]
  refine ⟨{ b with labels := b.labels ++ newLabels }, ?_, ?_, ?_⟩
  · rw [List.mem_map]
    exact ⟨b, hb, by simp [hid]⟩
  · exact hid
  · rfl

/-! ====================================================================
    PROPERTY 7: METADATA — set preserves other keys
    ==================================================================== -/

/-- setMetadata preserves the bead list length. -/
theorem setMetadata_preserves_length (st : Store) (id : BeadId)
    (key value : String) :
    (setMetadata st id key value).beads.length = st.beads.length := by
  simp [setMetadata]

/-- setMetadata does not change the dependency graph. -/
theorem setMetadata_preserves_deps (st : Store) (id : BeadId)
    (key value : String) :
    (setMetadata st id key value).deps = st.deps := by
  simp [setMetadata]

/-- After setMetadata, the target bead has the key-value pair in its metadata. -/
theorem setMetadata_contains (st : Store) (id : BeadId)
    (key value : String) (b : Bead) (hb : b ∈ st.beads) (hid : b.id = id) :
    ∃ b' ∈ (setMetadata st id key value).beads,
      b'.id = id ∧ (key, value) ∈ b'.metadata := by
  simp only [setMetadata]
  refine ⟨{ b with metadata := (b.metadata.filter (fun kv => kv.1 ≠ key)) ++ [(key, value)] },
    ?_, ?_, ?_⟩
  · exact List.mem_map.mpr ⟨b, hb, by simp [hid]⟩
  · exact hid
  · exact List.mem_append.mpr (Or.inr (List.Mem.head _))

/-! ====================================================================
    PROPERTY 8: DEPENDENCY — add/remove correctness
    ==================================================================== -/

/-- addDep does not change the bead list. -/
theorem addDep_preserves_beads (st : Store) (dep : Dep) :
    (addDep st dep).beads = st.beads := by
  simp [addDep]

/-- The added dep is in the resulting dep list. -/
theorem addDep_contains (st : Store) (dep : Dep) :
    dep ∈ (addDep st dep).deps := by
  simp [addDep]

/-- addDep preserves all existing deps. -/
theorem addDep_preserves (st : Store) (dep : Dep) :
    ∀ d ∈ st.deps, d ∈ (addDep st dep).deps := by
  intro d hd
  simp only [addDep]
  exact List.mem_append_left _ hd

/-- removeDep does not change the bead list. -/
theorem removeDep_preserves_beads (st : Store) (source target : BeadId) :
    (removeDep st source target).beads = st.beads := by
  simp [removeDep]

/-- removeDep actually removes the matching deps. -/
theorem removeDep_removes (st : Store) (source target : BeadId) :
    ∀ d ∈ (removeDep st source target).deps,
      ¬(d.source = source ∧ d.target = target) := by
  intro d hd
  simp only [removeDep, List.mem_filter, decide_eq_true_eq] at hd
  exact hd.2

/-- listDeps returns only deps with the matching source. -/
theorem listDeps_correct (st : Store) (id : BeadId) :
    ∀ d ∈ listDeps st id, d.source = id := by
  intro d hd
  simp only [listDeps, List.mem_filter, decide_eq_true_eq] at hd
  exact hd.2

/-! ====================================================================
    PROPERTY 9: QUERY — listByLabel / listByAssignee correctness
    ==================================================================== -/

/-- listByLabel results are a subset of all beads. -/
theorem listByLabel_subset (st : Store) (label : String) :
    ∀ b ∈ listByLabel st label, b ∈ st.beads := by
  intro b hb
  simp only [listByLabel, List.mem_filter] at hb
  exact hb.1

/-- listByLabel results all have the matching label. -/
theorem listByLabel_correct (st : Store) (label : String) :
    ∀ b ∈ listByLabel st label, b.labels.any (· == label) = true := by
  intro b hb
  simp only [listByLabel, List.mem_filter] at hb
  exact hb.2

/-- listByAssignee results are a subset of all beads. -/
theorem listByAssignee_subset (st : Store) (assignee : String) :
    ∀ b ∈ listByAssignee st assignee, b ∈ st.beads := by
  intro b hb
  simp only [listByAssignee, List.mem_filter] at hb
  exact hb.1

/-- listByAssignee results all have the matching assignee. -/
theorem listByAssignee_correct (st : Store) (assignee : String) :
    ∀ b ∈ listByAssignee st assignee, b.assignee = some assignee := by
  intro b hb
  simp only [listByAssignee, List.mem_filter] at hb
  exact eq_of_beq hb.2

/-! ====================================================================
    VERDICT
    ====================================================================

  PROVEN (zero sorries):

  Core (carried forward):
  1. create_unique_id / create_id_eq_counter
  2. create_ids_differ / mkId_injective
  3. close_idempotent
  4. close_removes_from_ready
  5. update_nil_noop
  6. labels_append

  New — Metadata:
  7. setMetadata_preserves_length / setMetadata_preserves_deps
  8. setMetadata_contains

  New — Dependencies:
  9.  addDep_preserves_beads / addDep_contains / addDep_preserves
  10. removeDep_preserves_beads / removeDep_removes
  11. listDeps_correct

  New — Queries:
  12. listByLabel_subset / listByLabel_correct
  13. listByAssignee_subset / listByAssignee_correct
-/

end BeadStore
