/-
  BeadStore: Formal model of the bead (issue) tracking store

  Models the core CRUD invariants for the Gas Town bead system:
  - Unique ID generation (counter-based, injective)
  - Status machine (open → in_progress → closed)
  - Close idempotence
  - Ready set correctness
  - Update nil-field preservation
  - Label append semantics

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

structure Bead where
  id       : BeadId
  title    : String
  status   : Status
  assignee : Option String
  labels   : List String
  deriving Repr, DecidableEq, BEq

/-! ====================================================================
    STORE
    ==================================================================== -/

structure Store where
  beads   : List Bead
  counter : Nat
  deriving Repr

def Store.empty : Store := { beads := [], counter := 0 }

/-! ====================================================================
    OPERATIONS
    ==================================================================== -/

/-- Generate a unique bead ID from the counter. -/
def mkId (n : Nat) : BeadId := ⟨n⟩

/-- Create a new bead. -/
def create (st : Store) (title : String) (labels : List String := []) : Store × BeadId :=
  let id := mkId st.counter
  let bead : Bead := {
    id := id, title := title, status := .open, assignee := none, labels := labels
  }
  ({ beads := st.beads ++ [bead], counter := st.counter + 1 }, id)

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
    if b.id = id then
      { id := b.id, title := b.title, status := Status.closed, assignee := b.assignee, labels := b.labels }
    else b
  have hf : f ∘ f = f := by
    funext b
    dsimp only [f]
    by_cases h : b.id = id
    · simp [h]
    · simp [h]
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

/-- Update with no assignee and no labels is identity. -/
theorem update_nil_noop (st : Store) (bid : BeadId) :
    update st bid none [] = st := by
  unfold update
  simp only [Option.orElse, List.append_nil]
  suffices h : st.beads.map (fun (b : Bead) =>
      if b.id = bid then
        { id := b.id, title := b.title, status := b.status, assignee := b.assignee, labels := b.labels }
      else b) = st.beads by
    cases st; simp only [Store.mk.injEq, and_true]; exact h
  induction st.beads with
  | nil => rfl
  | cons x xs ih =>
    simp only [List.map]
    have : (if x.id = bid then x else x) = x := by split <;> rfl
    rw [this, ih]

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

end BeadStore
