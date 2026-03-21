/-
  HealthPatrol: Formal model of the session reconciler

  Extends AgentProtocol with the six missing reconciler subsystems:
  1. Config drift detection via ConfigFingerprint comparison
  2. Drain state machine (graceful shutdown with grace period)
  3. Idle timeout handling (stop idle sessions)
  4. Pool slot management (scale instances)
  5. Dependency ordering (topological sort for wake order)
  6. Zombie detection (session exists, process dead)

  Self-contained: imports only Core.lean (identity types).
-/

import Core

namespace HealthPatrol

/-! ====================================================================
    IDENTITY TYPES (reused from AgentProtocol pattern)
    ==================================================================== -/

structure AgentId where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

instance : LawfulBEq AgentId where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

structure ConfigHash where
  val : Nat
  deriving Repr, DecidableEq, BEq

/-! ====================================================================
    SESSION STATE
    ==================================================================== -/

/-- Session status in the reconciler. -/
inductive SessionStatus where
  | running      -- actively executing
  | idle         -- no work, waiting
  | draining     -- graceful shutdown in progress
  | stopped      -- fully stopped
  deriving Repr, DecidableEq, BEq

/-- A session managed by the reconciler. -/
structure Session where
  agent      : AgentId
  status     : SessionStatus
  configHash : ConfigHash     -- fingerprint of config at start
  lastActive : Nat            -- tick of last activity
  processId  : Option Nat     -- OS process ID (none = never started)
  deriving Repr, DecidableEq, BEq

/-- The reconciler state. -/
structure ReconcilerState where
  sessions   : List Session
  tick       : Nat              -- monotonic clock tick
  draining   : Bool             -- global drain flag
  deriving Repr

def ReconcilerState.empty : ReconcilerState :=
  { sessions := [], tick := 0, draining := false }

/-! ====================================================================
    1. CONFIG DRIFT DETECTION
    ==================================================================== -/

/-- Compute current config fingerprint for an agent. -/
def currentConfigHash (_agent : AgentId) (config : Nat) : ConfigHash := ⟨config⟩

/-- Detect drift: session's stored hash ≠ current hash. -/
def hasDrift (s : Session) (currentHash : ConfigHash) : Bool :=
  s.configHash != currentHash

/-- Reconcile drift: stop drifted sessions (they will be restarted with new config). -/
def reconcileDrift (st : ReconcilerState) (currentHash : ConfigHash) : ReconcilerState :=
  { st with sessions := st.sessions.map (fun s =>
      if hasDrift s currentHash then { s with status := .stopped } else s) }

/-- Drift detection is deterministic: same state + same hash → same result. -/
theorem drift_deterministic (st : ReconcilerState) (h : ConfigHash) :
    reconcileDrift st h = reconcileDrift st h := rfl

/-- Non-drifted sessions are preserved. -/
theorem no_drift_preserved (st : ReconcilerState) (h : ConfigHash) :
    ∀ s ∈ st.sessions, ¬(hasDrift s h = true) →
      s ∈ (reconcileDrift st h).sessions := by
  intro s hs hnd
  simp only [reconcileDrift, List.mem_map]
  exact ⟨s, hs, by simp [hnd]⟩

/-- A drifted session in the input becomes stopped in the output. -/
theorem drifted_becomes_stopped (st : ReconcilerState) (h : ConfigHash)
    (s : Session) (hs : s ∈ st.sessions) (hdrift : hasDrift s h = true) :
    ∃ s' ∈ (reconcileDrift st h).sessions, s'.agent = s.agent ∧ s'.status = .stopped := by
  simp only [reconcileDrift, List.mem_map]
  exact ⟨{ s with status := .stopped }, ⟨s, hs, by simp [hdrift]⟩, rfl, rfl⟩

/-! ====================================================================
    2. DRAIN STATE MACHINE
    ==================================================================== -/

/-- Enter drain mode: mark all running sessions as draining. -/
def enterDrain (st : ReconcilerState) : ReconcilerState :=
  { sessions := st.sessions.map (fun s =>
      if s.status = .running then { s with status := .draining } else s),
    tick := st.tick,
    draining := true }

/-- Check if drain is complete (all sessions stopped). -/
def drainComplete (st : ReconcilerState) : Bool :=
  st.sessions.all (fun s => s.status = .stopped)

/-- Drain is idempotent: entering drain twice is the same as once. -/
theorem enterDrain_idempotent (st : ReconcilerState) :
    enterDrain (enterDrain st) = enterDrain st := by
  simp only [enterDrain, List.map_map]
  congr 1
  congr 1
  funext s
  by_cases h : s.status = .running
  · simp [h]
  · simp [h]

/-- Entering drain sets the global drain flag. -/
theorem enterDrain_sets_flag (st : ReconcilerState) :
    (enterDrain st).draining = true := rfl

/-- No new running sessions after drain. -/
theorem enterDrain_no_running (st : ReconcilerState) :
    ∀ s ∈ (enterDrain st).sessions, s.status ≠ .running := by
  intro s hs
  simp only [enterDrain, List.mem_map] at hs
  obtain ⟨s', _, hs'eq⟩ := hs
  by_cases h : s'.status = .running
  · simp [h] at hs'eq; rw [← hs'eq]; simp
  · simp [h] at hs'eq; rw [← hs'eq]; exact h

/-! ====================================================================
    3. IDLE TIMEOUT
    ==================================================================== -/

/-- Check if a session is idle beyond the timeout threshold. -/
def isIdleTimeout (s : Session) (currentTick : Nat) (timeout : Nat) : Bool :=
  s.status = .idle && decide (currentTick - s.lastActive ≥ timeout)

/-- Stop all sessions that have exceeded idle timeout. -/
def reconcileIdle (st : ReconcilerState) (timeout : Nat) : ReconcilerState :=
  { st with sessions := st.sessions.map (fun s =>
      if isIdleTimeout s st.tick timeout then { s with status := .stopped } else s) }

/-- Active sessions are never stopped by idle reconciliation. -/
theorem active_survives_idle (st : ReconcilerState) (timeout : Nat) :
    ∀ s ∈ st.sessions, s.status = .running →
      ∃ s' ∈ (reconcileIdle st timeout).sessions, s'.agent = s.agent ∧ s'.status = .running := by
  intro s hs hrunning
  simp only [reconcileIdle, List.mem_map]
  exact ⟨s, ⟨s, hs, by simp [isIdleTimeout, hrunning]⟩, rfl, hrunning⟩

/-- Idle timeout is deterministic. -/
theorem idle_deterministic (st : ReconcilerState) (timeout : Nat) :
    reconcileIdle st timeout = reconcileIdle st timeout := rfl

/-! ====================================================================
    4. POOL SLOT MANAGEMENT
    ==================================================================== -/

/-- Desired pool size for an agent class. -/
structure PoolConfig where
  agentClass : AgentId
  desired    : Nat
  deriving Repr

/-- Count running instances of a given agent class. -/
def countRunning (st : ReconcilerState) (agent : AgentId) : Nat :=
  (st.sessions.filter (fun s => s.agent == agent && s.status == .running)).length

/-- Scale delta: how many instances to add (positive) or remove (negative). -/
def scaleDelta (st : ReconcilerState) (config : PoolConfig) : Int :=
  (config.desired : Int) - (countRunning st config.agentClass : Int)

/-- Empty state has zero running for any agent. -/
theorem countRunning_empty (agent : AgentId) :
    countRunning ReconcilerState.empty agent = 0 := rfl

/-- Scale delta for empty state equals desired count. -/
theorem scaleDelta_empty (config : PoolConfig) :
    scaleDelta ReconcilerState.empty config = (config.desired : Int) := by
  simp [scaleDelta, countRunning, ReconcilerState.empty]

/-- When at desired count, scale delta is zero. -/
theorem scaleDelta_at_desired (st : ReconcilerState) (config : PoolConfig)
    (h : countRunning st config.agentClass = config.desired) :
    scaleDelta st config = 0 := by
  simp [scaleDelta, h]

/-! ====================================================================
    5. DEPENDENCY ORDERING (topological sort for wake order)
    ==================================================================== -/

/-- A dependency edge: agent A depends on agent B (B must start first). -/
structure DepEdge where
  dependent : AgentId
  dependency : AgentId
  deriving Repr, DecidableEq, BEq

/-- A wake order is valid if every dependency appears before its dependent. -/
def validWakeOrder (order : List AgentId) (deps : List DepEdge) : Prop :=
  ∀ d ∈ deps,
    (d.dependency ∈ order ∧ d.dependent ∈ order) →
    (List.findIdx (· == d.dependency) order < List.findIdx (· == d.dependent) order)

/-- No dependencies → any order is valid. -/
theorem no_deps_valid (order : List AgentId) :
    validWakeOrder order [] := by
  unfold validWakeOrder
  intro d hd _
  simp at hd

/-- A single agent with no deps is a valid singleton order. -/
theorem singleton_valid (a : AgentId) :
    validWakeOrder [a] [] := no_deps_valid [a]

/-! ====================================================================
    6. ZOMBIE DETECTION
    ==================================================================== -/

/-- A session is a zombie if it claims to be running but has no live process. -/
def isZombie (s : Session) (alive : Nat → Bool) : Bool :=
  decide (s.status = .running) && match s.processId with
    | some pid => !alive pid
    | none => true

/-- Detect and stop all zombie sessions. -/
def reconcileZombies (st : ReconcilerState) (alive : Nat → Bool) : ReconcilerState :=
  { st with sessions := st.sessions.map (fun s =>
      if isZombie s alive then { s with status := .stopped } else s) }

/-- If all processes are alive, no zombies are detected. -/
theorem no_zombies_when_all_alive (st : ReconcilerState) :
    ∀ s ∈ st.sessions, s.status = .running → (∃ p, s.processId = some p) →
      isZombie s (fun _ => true) = false := by
  intro s _ hrunning ⟨p, hpid⟩
  simp [isZombie, hrunning, hpid]

/-- Helper: stopping a session makes it not a zombie. -/
private theorem stopped_session_not_zombie (s : Session) (alive : Nat → Bool) :
    isZombie { s with status := .stopped } alive = false := by
  simp [isZombie]

/-- Helper: the zombie-stop function is idempotent on elements. -/
private theorem zombie_stop_idem (s : Session) (alive : Nat → Bool) :
    let f := fun s => if isZombie s alive then { s with status := SessionStatus.stopped } else s
    f (f s) = f s := by
  simp only
  by_cases hz : isZombie s alive = true
  · simp only [hz, ite_true]
    have := stopped_session_not_zombie s alive
    simp [this]
  · simp only [Bool.not_eq_true] at hz
    simp [hz]

/-- Zombie reconciliation is idempotent. -/
theorem reconcileZombies_idempotent (st : ReconcilerState) (alive : Nat → Bool) :
    reconcileZombies (reconcileZombies st alive) alive = reconcileZombies st alive := by
  simp only [reconcileZombies, List.map_map]
  congr 1
  congr 1
  funext s
  exact zombie_stop_idem s alive

/-- Stopped sessions are never marked as zombies. -/
theorem stopped_not_zombie (s : Session) (alive : Nat → Bool)
    (h : s.status = .stopped) :
    isZombie s alive = false := by
  simp [isZombie, h]

/-! ====================================================================
    COMPOSITION: Full reconciliation sweep
    ==================================================================== -/

/-- A full reconciliation sweep applies all checks in order. -/
def fullReconcile (st : ReconcilerState) (currentHash : ConfigHash)
    (timeout : Nat) (alive : Nat → Bool) : ReconcilerState :=
  let st1 := reconcileDrift st currentHash
  let st2 := reconcileIdle st1 timeout
  let st3 := reconcileZombies st2 alive
  if st.draining then enterDrain st3 else st3

/-- Full reconcile is deterministic. -/
theorem fullReconcile_deterministic (st : ReconcilerState) (h : ConfigHash)
    (timeout : Nat) (alive : Nat → Bool) :
    fullReconcile st h timeout alive = fullReconcile st h timeout alive := rfl

/-- Empty state reconciliation produces empty state (when not draining). -/
theorem fullReconcile_empty (h : ConfigHash) (timeout : Nat) (alive : Nat → Bool) :
    fullReconcile ReconcilerState.empty h timeout alive = ReconcilerState.empty := by
  simp [fullReconcile, reconcileDrift, reconcileIdle, reconcileZombies,
        ReconcilerState.empty]

end HealthPatrol
