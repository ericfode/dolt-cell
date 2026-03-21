/-
  HealthPatrol: Formal Model of Agent Health Monitoring

  Formalizes the witness/health-patrol quarantine mechanism.
  Agents that restart too many times within a time window are
  quarantined. Quarantine auto-expires when all restart timestamps
  age past the window.

  Key properties proved:
  1. Quarantine auto-expiry: when now > all timestamps + window,
     the in-window count is 0, so length ≤ maxRestarts.
  2. Quarantine monotonicity: adding restarts can only increase count.
  3. Fresh agent is healthy: no restarts → not quarantined.
  4. Window shrink: smaller window → fewer in-window restarts.

  Self-contained: imports only Core.lean (identity types).
-/

import Core

namespace HealthPatrol

/-! ====================================================================
    TYPES
    ==================================================================== -/

/-- A restart timestamp (monotonic Nat clock). -/
abbrev Timestamp := Nat

/-- Configuration for the health patrol. -/
structure PatrolConfig where
  maxRestarts : Nat      -- threshold: quarantine if exceeded
  windowSize  : Nat      -- time window to count restarts in
  deriving Repr, DecidableEq, BEq

/-- An agent's restart history. -/
structure AgentHealth where
  agentName  : PistonId
  restarts   : List Timestamp   -- append-only restart log
  deriving Repr

/-! ====================================================================
    QUARANTINE LOGIC
    ==================================================================== -/

/-- Restarts within the time window [now - windowSize, now]. -/
def restartsInWindow (restarts : List Timestamp) (now : Timestamp) (windowSize : Nat) : List Timestamp :=
  restarts.filter (fun t => decide (now - windowSize ≤ t))

/-- Count of restarts in window. -/
def restartCount (restarts : List Timestamp) (now : Timestamp) (windowSize : Nat) : Nat :=
  (restartsInWindow restarts now windowSize).length

/-- Is the agent quarantined? -/
def isQuarantined (health : AgentHealth) (config : PatrolConfig) (now : Timestamp) : Bool :=
  decide (restartCount health.restarts now config.windowSize > config.maxRestarts)

/-! ====================================================================
    PROPERTY 1: FRESH AGENT IS HEALTHY
    ==================================================================== -/

theorem fresh_agent_not_quarantined (pid : PistonId) (config : PatrolConfig) (now : Timestamp) :
    isQuarantined { agentName := pid, restarts := [] } config now = false := by
  simp [isQuarantined, restartCount, restartsInWindow, List.filter]

/-! ====================================================================
    PROPERTY 2: QUARANTINE AUTO-EXPIRY

    When all restart timestamps are older than the window
    (i.e., t < now - windowSize for all t in restarts),
    the in-window count is 0, so count ≤ maxRestarts.
    ==================================================================== -/

/-- When all timestamps are older than the window, restartsInWindow returns []. -/
theorem restartsInWindow_empty_when_aged
    (restarts : List Timestamp) (now windowSize : Nat)
    (hAged : ∀ t ∈ restarts, t < now - windowSize) :
    restartsInWindow restarts now windowSize = [] := by
  unfold restartsInWindow
  induction restarts with
  | nil => simp [List.filter]
  | cons x xs ih =>
    simp only [List.filter]
    have hx : x < now - windowSize := hAged x (by simp)
    have hd : decide (now - windowSize ≤ x) = false :=
      decide_eq_false (Nat.not_le.mpr hx)
    rw [hd]
    exact ih (fun t ht => hAged t (by simp [ht]))

/-- **Quarantine auto-expiry**: when all timestamps age past the window,
    restartCount = 0 ≤ maxRestarts, so the agent is not quarantined. -/
theorem quarantine_auto_expires
    (health : AgentHealth) (config : PatrolConfig) (now : Timestamp)
    (hAged : ∀ t ∈ health.restarts, t < now - config.windowSize) :
    isQuarantined health config now = false := by
  unfold isQuarantined restartCount
  rw [restartsInWindow_empty_when_aged health.restarts now config.windowSize hAged]
  simp

/-! ====================================================================
    PROPERTY 3: QUARANTINE MONOTONICITY
    Adding a restart can only increase the in-window count.
    ==================================================================== -/

theorem restartCount_mono_append (restarts : List Timestamp) (t now windowSize : Nat) :
    restartCount restarts now windowSize ≤ restartCount (restarts ++ [t]) now windowSize := by
  unfold restartCount restartsInWindow
  simp [List.filter_append, List.length_append]

/-- If not quarantined with extra restart, definitely not quarantined without. -/
theorem not_quarantined_of_fewer_restarts
    (health : AgentHealth) (config : PatrolConfig) (now : Timestamp) (t : Timestamp)
    (h : isQuarantined { health with restarts := health.restarts ++ [t] } config now = false) :
    isQuarantined health config now = false := by
  unfold isQuarantined at h ⊢
  simp only at h
  have hmono := restartCount_mono_append health.restarts t now config.windowSize
  rw [decide_eq_false_iff_not] at h ⊢
  omega

/-! ====================================================================
    PROPERTY 4: WINDOW SHRINK
    Smaller window → fewer in-window restarts.
    ==================================================================== -/

theorem restartsInWindow_subset_of_smaller_window
    (restarts : List Timestamp) (now w1 w2 : Nat) (hw : w1 ≤ w2) :
    ∀ t ∈ restartsInWindow restarts now w1,
      t ∈ restartsInWindow restarts now w2 := by
  intro t ht
  unfold restartsInWindow at ht ⊢
  simp [List.mem_filter] at ht ⊢
  constructor
  · exact ht.1
  · omega

/-! ====================================================================
    ADDITIONAL: EXACT THRESHOLD
    ==================================================================== -/

/-- At exactly maxRestarts, not quarantined (as Prop). -/
theorem at_threshold_not_quarantined (restarts : List Timestamp) (now windowSize maxRestarts : Nat)
    (h : restartCount restarts now windowSize ≤ maxRestarts) :
    ¬ (restartCount restarts now windowSize > maxRestarts) := by
  omega

/-! ====================================================================
    VERDICT: HealthPatrol Properties
    ====================================================================

  PROVEN:

  1. fresh_agent_not_quarantined
     An agent with no restart history is never quarantined.

  2. quarantine_auto_expires
     When all restart timestamps age past the window
     (∀ t ∈ restarts, t < now - windowSize),
     the agent is automatically un-quarantined.

  3. restartCount_mono_append
     Adding a restart to the log can only increase the
     in-window count (monotonicity).

  4. not_quarantined_of_fewer_restarts
     Contrapositive: if not quarantined with more restarts,
     then not quarantined with fewer.

  5. restartsInWindow_subset_of_smaller_window
     A smaller window yields a subset of restarts.

  6. at_threshold_not_quarantined
     At exactly maxRestarts count, the quarantine check is false.
-/

end HealthPatrol
