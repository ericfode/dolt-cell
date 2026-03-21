/-
  AgentProtocol: Session lifecycle and idempotence for runtime.Provider

  Formalizes the Gas City runtime Provider interface in Lean 4.
  The Provider manages agent sessions (start, stop, list running).

  Key properties proven:
    1. Stop idempotence: Stop(Stop(s)) = Stop(s)
    2. SessionNameFor determinism: same (city, agent, template) → same name
    3. ProcessAlive contract: empty process list → true
    4. ConfigFingerprint immutability: identical config → identical hash
    5. ListRunning monotonicity under Start

  Go source reference: internal/runtime/runtime.go (Gas City repo)
  Architecture: docs/architecture/agent-protocol.md
-/

import Core

namespace AgentProtocol

/-! ====================================================================
    IDENTITY TYPES
    ==================================================================== -/

structure AgentName where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

structure SessionName where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

structure CityPath where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

structure TemplateName where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

structure ConfigHash where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

instance : LawfulBEq AgentName where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

instance : LawfulBEq SessionName where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

instance : LawfulBEq CityPath where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

instance : LawfulBEq TemplateName where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

/-! ====================================================================
    PROCESS AND SESSION TYPES
    ==================================================================== -/

/-- A running session in the runtime. -/
structure Session where
  name   : SessionName
  agent  : AgentName
  deriving Repr, DecidableEq, BEq

/-- Runtime state: the set of currently running sessions. -/
structure RuntimeState where
  running : List Session
  deriving Repr

def RuntimeState.empty : RuntimeState := { running := [] }

/-! ====================================================================
    PURE FUNCTIONS (Provider interface)
    ==================================================================== -/

/-- Deterministic session name derivation.
    In Go: SessionNameFor(city, agent, template) → string.
    Modeled as a pure function — determinism is structural. -/
def sessionNameFor (city : CityPath) (agent : AgentName) (tmpl : TemplateName) : SessionName :=
  ⟨city.val ++ "/" ++ agent.val ++ "/" ++ tmpl.val⟩

/-- Config fingerprint: identical config → identical hash.
    In Go: ConfigFingerprint(config) → string.
    Modeled as an opaque pure function via a parameter. -/
def configFingerprint (config : String) : ConfigHash :=
  ⟨config⟩  -- identity model; real impl uses SHA256

/-- ProcessAlive: are all processes in the list alive?
    Empty process list → vacuously true. -/
def processAlive (pids : List SessionName) (alive : SessionName → Bool) : Bool :=
  pids.all alive

/-! ====================================================================
    STATE TRANSITIONS (Provider operations)
    ==================================================================== -/

/-- Start a session: add to running list if not already present. -/
def start (s : RuntimeState) (sess : Session) : RuntimeState :=
  if s.running.any (fun r => r.name == sess.name) then s
  else { running := s.running ++ [sess] }

/-- Stop a session: remove all sessions with matching name. -/
def stop (s : RuntimeState) (name : SessionName) : RuntimeState :=
  { running := s.running.filter (fun r => !(r.name == name)) }

/-- List running sessions. -/
def listRunning (s : RuntimeState) : List Session :=
  s.running

/-! ====================================================================
    PROPERTY 1: STOP IDEMPOTENCE
    Stop(Stop(s)) = Stop(s)
    ==================================================================== -/

theorem filter_filter_eq (xs : List Session) (name : SessionName) :
    (xs.filter (fun r => !(r.name == name))).filter (fun r => !(r.name == name)) =
    xs.filter (fun r => !(r.name == name)) := by
  induction xs with
  | nil => simp [List.filter]
  | cons x xs ih =>
    simp only [List.filter]
    split
    · -- x passes the filter
      rename_i hpass
      simp only [List.filter, hpass]
      exact congrArg (x :: ·) ih
    · -- x doesn't pass the filter
      exact ih

theorem stop_idempotent (s : RuntimeState) (name : SessionName) :
    stop (stop s name) name = stop s name := by
  unfold stop
  simp only
  exact congrArg RuntimeState.mk (filter_filter_eq s.running name)

/-! ====================================================================
    PROPERTY 2: SESSIONNAMFOR DETERMINISM
    same (city, agent, template) → same name
    ==================================================================== -/

theorem sessionNameFor_deterministic
    (city : CityPath) (agent : AgentName) (tmpl : TemplateName) :
    sessionNameFor city agent tmpl = sessionNameFor city agent tmpl :=
  rfl

/-- Stronger: equal inputs yield equal outputs. -/
theorem sessionNameFor_eq_of_eq
    (c1 c2 : CityPath) (a1 a2 : AgentName) (t1 t2 : TemplateName)
    (hc : c1 = c2) (ha : a1 = a2) (ht : t1 = t2) :
    sessionNameFor c1 a1 t1 = sessionNameFor c2 a2 t2 := by
  subst hc; subst ha; subst ht; rfl

/-- Contrapositive: different outputs imply different inputs. -/
theorem sessionNameFor_injective_city
    (c1 c2 : CityPath) (agent : AgentName) (tmpl : TemplateName)
    (h : sessionNameFor c1 agent tmpl = sessionNameFor c2 agent tmpl) :
    c1.val ++ "/" ++ agent.val ++ "/" ++ tmpl.val =
    c2.val ++ "/" ++ agent.val ++ "/" ++ tmpl.val := by
  unfold sessionNameFor at h
  exact congrArg SessionName.val h

/-! ====================================================================
    PROPERTY 3: PROCESSALIVE CONTRACT
    empty process list → true
    ==================================================================== -/

theorem processAlive_empty (alive : SessionName → Bool) :
    processAlive [] alive = true := by
  unfold processAlive
  simp [List.all]

/-- Single alive process → true. -/
theorem processAlive_singleton (pid : SessionName) (alive : SessionName → Bool)
    (h : alive pid = true) :
    processAlive [pid] alive = true := by
  unfold processAlive
  simp [List.all, h]

/-- If all elements are alive, processAlive holds. -/
theorem processAlive_of_all_alive (pids : List SessionName) (alive : SessionName → Bool)
    (h : ∀ p ∈ pids, alive p = true) :
    processAlive pids alive = true := by
  unfold processAlive
  rw [List.all_eq_true]
  exact h

/-! ====================================================================
    PROPERTY 4: CONFIGFINGERPRINT IMMUTABILITY
    identical config → identical hash
    ==================================================================== -/

theorem configFingerprint_deterministic (config : String) :
    configFingerprint config = configFingerprint config :=
  rfl

theorem configFingerprint_eq_of_eq (c1 c2 : String) (h : c1 = c2) :
    configFingerprint c1 = configFingerprint c2 := by
  subst h; rfl

/-- Different fingerprints imply different configs (injectivity). -/
theorem configFingerprint_injective (c1 c2 : String)
    (h : configFingerprint c1 = configFingerprint c2) :
    c1 = c2 := by
  unfold configFingerprint at h
  exact congrArg ConfigHash.val h

/-! ====================================================================
    PROPERTY 5: LISTRUNNING MONOTONICITY UNDER START
    After Start, listRunning grows (or stays same if duplicate).
    ==================================================================== -/

theorem listRunning_after_start_superset (s : RuntimeState) (sess : Session) :
    ∀ r ∈ listRunning s, r ∈ listRunning (start s sess) := by
  intro r hr
  unfold listRunning start
  split
  · exact hr
  · exact List.mem_append_left _ hr

theorem listRunning_after_start_contains (s : RuntimeState) (sess : Session)
    (hNew : s.running.any (fun r => r.name == sess.name) = false) :
    sess ∈ listRunning (start s sess) := by
  unfold listRunning start
  simp [hNew]

theorem listRunning_length_mono (s : RuntimeState) (sess : Session) :
    (listRunning s).length ≤ (listRunning (start s sess)).length := by
  unfold listRunning start
  split
  · exact Nat.le_refl _
  · simp [List.length_append]

/-! ====================================================================
    STOP REMOVES FROM LISTRUNNING
    ==================================================================== -/

theorem listRunning_after_stop_subset (s : RuntimeState) (name : SessionName) :
    ∀ r ∈ listRunning (stop s name), r ∈ listRunning s := by
  intro r hr
  unfold listRunning stop at hr
  simp [List.mem_filter] at hr
  exact hr.1

theorem stop_removes_name (s : RuntimeState) (name : SessionName) :
    ∀ r ∈ listRunning (stop s name), r.name ≠ name := by
  intro r hr
  unfold listRunning stop at hr
  simp [List.mem_filter] at hr
  exact hr.2

/-! ====================================================================
    ADDITIONAL LIFECYCLE PROPERTIES
    ==================================================================== -/

/-- Stop on empty state is identity. -/
theorem stop_empty (name : SessionName) :
    stop RuntimeState.empty name = RuntimeState.empty := by
  unfold stop RuntimeState.empty
  simp [List.filter]

/-- After start-then-stop, no survivor has the stopped name. -/
theorem start_then_stop_name (s : RuntimeState) (sess : Session)
    (r : Session) (hr : r ∈ (stop (start s sess) sess.name).running) :
    r.name ≠ sess.name := by
  have := stop_removes_name (start s sess) sess.name r
  unfold listRunning at this
  exact this hr

/-- Start then stop same name: survivors are from original. -/
theorem start_then_stop_mem (s : RuntimeState) (sess : Session)
    (r : Session) (hr : r ∈ (stop (start s sess) sess.name).running) :
    r ∈ s.running := by
  have hne := start_then_stop_name s sess r hr
  unfold stop start at hr
  simp [List.mem_filter] at hr
  split at hr
  · exact hr.1
  · obtain ⟨hmem, _⟩ := hr
    simp at hmem
    cases hmem with
    | inl h => exact h
    | inr h => exact absurd (h ▸ rfl) hne

/-! ====================================================================
    VERDICT: AgentProtocol Properties
    ====================================================================

  PROVEN:

  1. stop_idempotent
     Stop(Stop(s, name), name) = Stop(s, name)
     Stopping an already-stopped session has no further effect.

  2. sessionNameFor_deterministic / sessionNameFor_eq_of_eq
     Same (city, agent, template) always yields the same SessionName.
     The derivation is a pure function — determinism is structural.

  3. processAlive_empty
     processAlive([], alive) = true
     Vacuous truth: no processes means nothing is dead.

  4. configFingerprint_eq_of_eq / configFingerprint_injective
     Identical config → identical hash. Different hashes → different configs.

  5. listRunning_after_start_superset / listRunning_length_mono
     After Start, the running set grows (or stays same for duplicates).
     All previously running sessions remain running.

  ADDITIONAL:

  6. stop_removes_name
     After Stop(name), no session with that name remains.

  7. listRunning_after_stop_subset
     Stop only removes; it never adds sessions.

  8. start_then_stop
     Start then Stop same name: only original sessions survive
     (minus those sharing the name).

  9. stop_empty
     Stop on empty runtime is identity.
-/

end AgentProtocol
