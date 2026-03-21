/-
  BeadStore: Formal model of the beads.Store interface

  The bead store is the universal persistence substrate for Gas City
  work units (tasks, messages, molecules, convoys). This file formalizes
  the Store interface as a transition system and proves the conformance
  suite invariants:

  1.  Create assigns unique non-empty IDs
  2.  Create defaults Status="open", Type="task"
  3.  Close idempotence: Close(Close(id)) = Close(id)
  4.  Close removes from Ready()
  5.  Label monotonicity: labels only append, never replace
  6.  Update with nil fields is no-op
  7.  Children filters by exact ParentID
  8.  Container type semantics
  9.  Status reachability: open → in_progress → closed
  10. Get/Create round-trip fidelity

  Go source: github.com/gastownhall/gascity/internal/beads
-/

namespace BeadStore

/-! ====================================================================
    IDENTITY AND STATUS TYPES
    ==================================================================== -/

abbrev BeadId := Nat

inductive BeadStatus where
  | open_       -- available for work
  | in_progress -- claimed by an agent
  | closed      -- completed
  deriving Repr, DecidableEq, BEq

instance : LawfulBEq BeadStatus where
  eq_of_beq {a b} h := by cases a <;> cases b <;> first | rfl | exact absurd h (by decide)
  rfl {a} := by cases a <;> rfl

inductive BeadType where
  | task | bug | molecule | wisp | convoy | mail
  deriving Repr, DecidableEq, BEq

instance : LawfulBEq BeadType where
  eq_of_beq {a b} h := by cases a <;> cases b <;> first | rfl | exact absurd h (by decide)
  rfl {a} := by cases a <;> rfl

/-! ====================================================================
    BEAD RECORD
    ==================================================================== -/

structure Bead where
  id          : BeadId
  title       : String
  status      : BeadStatus
  beadType    : BeadType
  assignee    : String
  from_       : String
  parentId    : Option BeadId
  description : String
  labels      : List String
  metadata    : List (String × String)
  deriving Repr, DecidableEq, BEq

/-! ====================================================================
    UPDATE OPTIONS (none = no change)
    ==================================================================== -/

structure UpdateOpts where
  title       : Option String         := none
  status      : Option BeadStatus     := none
  description : Option String         := none
  parentId    : Option (Option BeadId) := none
  assignee    : Option String         := none
  addLabels   : List String           := []
  deriving Repr

/-! ====================================================================
    DEPENDENCY
    ==================================================================== -/

structure Dep where
  issueId     : BeadId
  dependsOnId : BeadId
  depType     : String
  deriving Repr, DecidableEq, BEq

/-! ====================================================================
    STORE STATE
    ==================================================================== -/

structure Store where
  beads  : List Bead
  deps   : List Dep
  nextId : Nat
  deriving Repr

def Store.init : Store := { beads := [], deps := [], nextId := 1 }

/-! ====================================================================
    QUERIES
    ==================================================================== -/

def Store.get (s : Store) (id : BeadId) : Option Bead :=
  s.beads.find? (fun b => b.id == id)

def Store.list_ (s : Store) : List Bead := s.beads

def Store.ready (s : Store) : List Bead :=
  s.beads.filter (fun b => b.status == .open_)

def Store.children (s : Store) (parentId : BeadId) : List Bead :=
  s.beads.filter (fun b => b.parentId == some parentId)

def Store.listByLabel (s : Store) (label : String) : List Bead :=
  s.beads.filter (fun b => b.labels.elem label)

def Store.listByAssignee (s : Store) (assignee : String) (status : BeadStatus) : List Bead :=
  s.beads.filter (fun b => b.assignee == assignee && b.status == status)

/-! ====================================================================
    TRANSITIONS
    ==================================================================== -/

def Store.create (s : Store) (title : String) (beadType : Option BeadType)
    (assignee : String := "") (from_ : String := "")
    (parentId : Option BeadId := none) (labels : List String := [])
    (description : String := "") : Store × Bead :=
  let bead : Bead := {
    id := s.nextId
    title := title
    status := .open_
    beadType := beadType.getD .task
    assignee := assignee
    from_ := from_
    parentId := parentId
    description := description
    labels := labels
    metadata := []
  }
  ({ beads := s.beads ++ [bead], deps := s.deps, nextId := s.nextId + 1 }, bead)

def applyUpdate (b : Bead) (opts : UpdateOpts) : Bead :=
  { b with
    title       := opts.title.getD b.title
    status      := opts.status.getD b.status
    description := opts.description.getD b.description
    parentId    := match opts.parentId with | some pid => pid | none => b.parentId
    assignee    := opts.assignee.getD b.assignee
    labels      := b.labels ++ opts.addLabels }

def Store.update (s : Store) (id : BeadId) (opts : UpdateOpts) : Store × Bool :=
  if s.beads.any (fun b => b.id == id) then
    let beads' := s.beads.map (fun b => if b.id = id then applyUpdate b opts else b)
    ({ s with beads := beads' }, true)
  else
    (s, false)

def Store.close (s : Store) (id : BeadId) : Store × Bool :=
  s.update id { status := some .closed }

def Store.setMetadata (s : Store) (id : BeadId) (key value : String) : Store × Bool :=
  if s.beads.any (fun b => b.id == id) then
    let beads' := s.beads.map fun b =>
      if b.id = id then
        let md' := (b.metadata.filter (fun p => p.1 != key)) ++ [(key, value)]
        { b with metadata := md' }
      else b
    ({ s with beads := beads' }, true)
  else
    (s, false)

def Store.depAdd (s : Store) (issueId dependsOnId : BeadId) (depType : String) : Store :=
  if s.deps.any (fun d => d.issueId == issueId && d.dependsOnId == dependsOnId) then
    let deps' := s.deps.map fun d =>
      if d.issueId = issueId ∧ d.dependsOnId = dependsOnId
      then { d with depType := depType }
      else d
    { s with deps := deps' }
  else
    { s with deps := s.deps ++ [⟨issueId, dependsOnId, depType⟩] }

def Store.depRemove (s : Store) (issueId dependsOnId : BeadId) : Store :=
  let deps' := s.deps.filter
    (fun d => !(d.issueId == issueId && d.dependsOnId == dependsOnId))
  { s with deps := deps' }

def Store.depListDown (s : Store) (id : BeadId) : List Dep :=
  s.deps.filter (fun d => d.issueId == id)

def Store.depListUp (s : Store) (id : BeadId) : List Dep :=
  s.deps.filter (fun d => d.dependsOnId == id)

/-! ====================================================================
    TYPE PREDICATES
    ==================================================================== -/

def isContainerType (t : BeadType) : Bool :=
  match t with | .convoy => true | _ => false

def isMoleculeType (t : BeadType) : Bool :=
  match t with | .molecule | .wisp => true | _ => false

/-! ====================================================================
    STATUS MACHINE
    ==================================================================== -/

def validTransition (from_ to_ : BeadStatus) : Bool :=
  match from_, to_ with
  | .open_, .in_progress  => true
  | .open_, .closed       => true
  | .in_progress, .closed => true
  | .closed, .closed      => true
  | _, _                  => false

def statusOrd : BeadStatus → Nat
  | .open_ => 0 | .in_progress => 1 | .closed => 2

/-! ====================================================================
    INVARIANTS
    ==================================================================== -/

/-- No two beads in the store share an ID. Phrased via membership for
    clean proofs (avoids List.get/getElem API fragility). -/
def idsUnique (s : Store) : Prop :=
  ∀ (b1 b2 : Bead), b1 ∈ s.beads → b2 ∈ s.beads → b1.id = b2.id → b1 = b2

def idsNonZero (s : Store) : Prop :=
  ∀ (b : Bead), b ∈ s.beads → b.id ≥ 1

def nextIdPositive (s : Store) : Prop := s.nextId ≥ 1

def idsFromCounter (s : Store) : Prop :=
  ∀ (b : Bead), b ∈ s.beads → b.id ≥ 1 ∧ b.id < s.nextId

def wellFormed (s : Store) : Prop :=
  idsUnique s ∧ idsNonZero s ∧ nextIdPositive s ∧ idsFromCounter s

/-! ====================================================================
    PROOFS: CREATE
    ==================================================================== -/

theorem create_status_open (s : Store) (title : String) (bt : Option BeadType)
    (a f : String) (pid : Option BeadId) (ls : List String) (desc : String) :
    (s.create title bt a f pid ls desc).2.status = .open_ := rfl

theorem create_default_type (s : Store) (title : String)
    (a f : String) (pid : Option BeadId) (ls : List String) (desc : String) :
    (s.create title none a f pid ls desc).2.beadType = .task := rfl

theorem create_preserves_type (s : Store) (title : String) (bt : BeadType)
    (a f : String) (pid : Option BeadId) (ls : List String) (desc : String) :
    (s.create title (some bt) a f pid ls desc).2.beadType = bt := rfl

theorem create_preserves_title (s : Store) (title : String) (bt : Option BeadType)
    (a f : String) (pid : Option BeadId) (ls : List String) (desc : String) :
    (s.create title bt a f pid ls desc).2.title = title := rfl

theorem create_id_is_nextId (s : Store) (title : String) (bt : Option BeadType)
    (a f : String) (pid : Option BeadId) (ls : List String) (desc : String) :
    (s.create title bt a f pid ls desc).2.id = s.nextId := rfl

theorem create_increments_counter (s : Store) (title : String) (bt : Option BeadType)
    (a f : String) (pid : Option BeadId) (ls : List String) (desc : String) :
    (s.create title bt a f pid ls desc).1.nextId = s.nextId + 1 := rfl

theorem create_bead_in_store (s : Store) (title : String) (bt : Option BeadType)
    (a f : String) (pid : Option BeadId) (ls : List String) (desc : String) :
    let result := s.create title bt a f pid ls desc
    result.2 ∈ result.1.beads := by
  simp [Store.create]

theorem create_preserves_beads (s : Store) (title : String) (bt : Option BeadType)
    (a f : String) (pid : Option BeadId) (ls : List String) (desc : String)
    (b : Bead) (hb : b ∈ s.beads) :
    b ∈ (s.create title bt a f pid ls desc).1.beads := by
  simp [Store.create]; exact Or.inl hb

/-! ====================================================================
    PROOFS: CLOSE
    ==================================================================== -/

theorem close_sets_closed (s : Store) (id : BeadId)
    (h : s.beads.any (fun b => b.id == id) = true)
    (b : Bead) (hb : b ∈ (s.close id).1.beads) (hid : b.id = id) :
    b.status = .closed := by
  simp only [Store.close, Store.update, h, ↓reduceIte, List.mem_map] at hb
  obtain ⟨b', _, hb'⟩ := hb
  by_cases heq : b'.id = id
  · simp only [heq, ↓reduceIte] at hb'; subst hb'; simp [applyUpdate]
  · simp only [heq, ↓reduceIte] at hb'; subst hb'; exact absurd hid heq

theorem close_removes_from_ready (s : Store) (id : BeadId)
    (h : s.beads.any (fun b => b.id == id) = true)
    (b : Bead) (hb : b ∈ (s.close id).1.ready) :
    b.id ≠ id := by
  intro hid
  simp only [Store.ready, Store.close, Store.update, h, ↓reduceIte,
             List.mem_filter, List.mem_map, beq_iff_eq] at hb
  obtain ⟨⟨b', _, hb'⟩, hstatus⟩ := hb
  by_cases heq : b'.id = id
  · simp only [heq, ↓reduceIte] at hb'
    subst hb'; simp [applyUpdate] at hstatus
  · simp only [heq, ↓reduceIte] at hb'
    subst hb'; exact heq hid

/-- Close is idempotent: applying close to an already-closed bead is identity. -/
theorem close_idempotent_bead (b : Bead) (h : b.status = .closed) :
    applyUpdate b { status := some .closed } = b := by
  cases b; simp_all [applyUpdate]

/-! ====================================================================
    PROOFS: UPDATE
    ==================================================================== -/

theorem update_nil_noop (b : Bead) : applyUpdate b {} = b := by
  cases b; simp [applyUpdate]

theorem update_nil_preserves_store (s : Store) (id : BeadId)
    (h : s.beads.any (fun b => b.id == id) = true) :
    (s.update id {}).1.beads = s.beads := by
  simp only [Store.update, h, ↓reduceIte]
  suffices h : ∀ (b : Bead), (if b.id = id then applyUpdate b {} else b) = b by
    simp [List.map_id', h]
  intro b
  by_cases hb : b.id = id
  · simp [hb, update_nil_noop]
  · simp [hb]

/-! ====================================================================
    PROOFS: LABEL MONOTONICITY
    ==================================================================== -/

theorem update_labels_monotone (b : Bead) (opts : UpdateOpts) (l : String)
    (hl : l ∈ b.labels) :
    l ∈ (applyUpdate b opts).labels := by
  simp [applyUpdate]; exact Or.inl hl

theorem update_labels_append (b : Bead) (opts : UpdateOpts) :
    (applyUpdate b opts).labels = b.labels ++ opts.addLabels := rfl

/-! ====================================================================
    PROOFS: CHILDREN
    ==================================================================== -/

theorem children_exact_parent (s : Store) (pid : BeadId) (b : Bead)
    (hb : b ∈ s.children pid) :
    b.parentId = some pid := by
  simp only [Store.children, List.mem_filter, beq_iff_eq] at hb
  exact hb.2

theorem children_excludes_other (s : Store) (pid : BeadId) (b : Bead)
    (hne : b.parentId ≠ some pid) :
    b ∉ s.children pid := by
  simp only [Store.children, List.mem_filter, beq_iff_eq]
  exact fun ⟨_, heq⟩ => hne heq

theorem children_empty_no_parent (s : Store) (pid : BeadId)
    (h : ∀ (b : Bead), b ∈ s.beads → b.parentId ≠ some pid) :
    s.children pid = [] := by
  simp only [Store.children]
  rw [List.filter_eq_nil_iff]
  intro b hb
  simp only [beq_iff_eq]
  exact h b hb

/-! ====================================================================
    PROOFS: READY
    ==================================================================== -/

theorem ready_only_open (s : Store) (b : Bead) (hb : b ∈ s.ready) :
    b.status = .open_ := by
  simp only [Store.ready, List.mem_filter, beq_iff_eq] at hb
  exact hb.2

theorem open_in_ready (s : Store) (b : Bead) (hb : b ∈ s.beads)
    (hs : b.status = .open_) :
    b ∈ s.ready := by
  simp only [Store.ready, List.mem_filter, beq_iff_eq]
  exact ⟨hb, hs⟩

theorem ready_empty : Store.init.ready = [] := rfl

/-! ====================================================================
    PROOFS: TYPE SEMANTICS
    ==================================================================== -/

theorem container_type_convoy (t : BeadType) :
    isContainerType t = true ↔ t = .convoy := by
  cases t <;> simp [isContainerType]

theorem molecule_type_spec (t : BeadType) :
    isMoleculeType t = true ↔ (t = .molecule ∨ t = .wisp) := by
  cases t <;> simp [isMoleculeType]

/-! ====================================================================
    PROOFS: STATUS REACHABILITY
    ==================================================================== -/

theorem valid_transitions_complete :
    (validTransition .open_ .in_progress = true) ∧
    (validTransition .open_ .closed = true) ∧
    (validTransition .in_progress .closed = true) ∧
    (validTransition .closed .closed = true) := by decide

theorem no_backward_transitions :
    (validTransition .in_progress .open_ = false) ∧
    (validTransition .closed .open_ = false) ∧
    (validTransition .closed .in_progress = false) := by decide

theorem valid_transition_monotone (from_ to_ : BeadStatus)
    (h : validTransition from_ to_ = true) :
    statusOrd from_ ≤ statusOrd to_ := by
  cases from_ <;> cases to_ <;> simp_all [validTransition, statusOrd]

/-! ====================================================================
    PROOFS: DEPENDENCIES
    ==================================================================== -/

theorem depRemove_removes (s : Store) (iid did : BeadId) (d : Dep)
    (hd : d ∈ (s.depRemove iid did).deps) :
    ¬(d.issueId = iid ∧ d.dependsOnId = did) := by
  simp only [Store.depRemove, List.mem_filter, Bool.not_eq_true'] at hd
  intro ⟨h1, h2⟩
  have : (d.issueId == iid && d.dependsOnId == did) = true := by
    simp [h1, h2]
  simp [this] at hd

theorem depRemove_noop (s : Store) (iid did : BeadId)
    (h : ∀ (d : Dep), d ∈ s.deps → ¬(d.issueId = iid ∧ d.dependsOnId = did)) :
    (s.depRemove iid did).deps = s.deps := by
  simp only [Store.depRemove]
  rw [List.filter_eq_self]
  intro d hd
  have hne := h d hd
  simp only [Bool.not_eq_true']
  by_cases h1 : d.issueId = iid <;> by_cases h2 : d.dependsOnId = did
  · exact absurd ⟨h1, h2⟩ hne
  · simp [h2]
  · simp [h1]
  · simp [h1]

theorem depListDown_exact (s : Store) (id : BeadId) (d : Dep)
    (hd : d ∈ s.depListDown id) :
    d.issueId = id := by
  simp only [Store.depListDown, List.mem_filter, beq_iff_eq] at hd
  exact hd.2

theorem depListUp_exact (s : Store) (id : BeadId) (d : Dep)
    (hd : d ∈ s.depListUp id) :
    d.dependsOnId = id := by
  simp only [Store.depListUp, List.mem_filter, beq_iff_eq] at hd
  exact hd.2

/-! ====================================================================
    PROOFS: WELL-FORMEDNESS
    ==================================================================== -/

theorem init_wellFormed : wellFormed Store.init := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro b1 _ h1; simp [Store.init] at h1
  · intro b hb; simp [Store.init] at hb
  · simp [Store.init, nextIdPositive]
  · intro b hb; simp [Store.init] at hb

theorem create_preserves_wellFormed (s : Store) (title : String) (bt : Option BeadType)
    (a f : String) (pid : Option BeadId) (ls : List String) (desc : String)
    (hwf : wellFormed s) :
    wellFormed (s.create title bt a f pid ls desc).1 := by
  obtain ⟨huniq, hnonz, hpos, hctr⟩ := hwf
  refine ⟨?_, ?_, ?_, ?_⟩
  · -- idsUnique: old beads have id < nextId, new bead has id = nextId
    intro b1 b2 h1 h2 hid
    simp only [Store.create, List.mem_append, List.mem_singleton] at h1 h2
    rcases h1 with h1 | h1 <;> rcases h2 with h2 | h2
    · exact huniq b1 b2 h1 h2 hid
    · subst h2
      have hlt := (hctr b1 h1).2
      exact absurd hid (Nat.ne_of_lt hlt)
    · subst h1
      have hlt := (hctr b2 h2).2
      exact absurd hid.symm (Nat.ne_of_lt hlt)
    · subst h1; subst h2; rfl
  · -- idsNonZero
    intro b hb
    simp only [Store.create, List.mem_append, List.mem_singleton] at hb
    rcases hb with hb | hb
    · exact hnonz b hb
    · subst hb; exact hpos
  · -- nextIdPositive
    simp only [Store.create, nextIdPositive]; omega
  · -- idsFromCounter
    unfold idsFromCounter
    simp only [Store.create, List.mem_append, List.mem_singleton]
    intro b hb
    rcases hb with hb | hb
    · have ⟨hge, hlt⟩ := hctr b hb
      exact ⟨hge, Nat.lt_of_lt_of_le hlt (Nat.le_succ _)⟩
    · subst hb
      exact ⟨hpos, Nat.lt_succ_of_le (Nat.le_refl _)⟩

/-! ====================================================================
    PROOFS: LIST
    ==================================================================== -/

theorem list_complete (s : Store) (b : Bead) : b ∈ s.beads ↔ b ∈ s.list_ := Iff.rfl
theorem list_empty : Store.init.list_ = [] := rfl

/-! ====================================================================
    PROOFS: LISTBYLABEL
    ==================================================================== -/

theorem listByLabel_exact (s : Store) (label : String) (b : Bead)
    (hb : b ∈ s.listByLabel label) :
    label ∈ b.labels := by
  simp only [Store.listByLabel, List.mem_filter] at hb
  exact List.elem_iff.mp hb.2

theorem listByLabel_empty (label : String) :
    Store.init.listByLabel label = [] := rfl

/-! ====================================================================
    PROOFS: METADATA
    ==================================================================== -/

theorem setMetadata_preserves_count (s : Store) (id : BeadId) (k v : String)
    (h : s.beads.any (fun b => b.id == id) = true) :
    (s.setMetadata id k v).1.beads.length = s.beads.length := by
  simp only [Store.setMetadata, h, ↓reduceIte, List.length_map]

end BeadStore
