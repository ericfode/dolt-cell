/-
  GasCity.HealthPatrol — Derived Mechanism 9: crash tracking and reconciliation

  Models Erlang/OTP-style one-for-one restart with sliding window
  crash tracking and auto-expiring quarantine.

  DERIVATION CLAIM: Health Patrol uses only P1 + P3 + P4.
  ACTUAL Go IMPLEMENTATION (session_reconciler.go, 400+ lines):
    The claim holds for the decision logic but the full reconciler also:
    - Detects config drift via ConfigFingerprint comparison (not modeled)
    - Handles idle timeout (not modeled)
    - Manages drain state machine for graceful shutdown (not modeled)
    - Tracks pool slots and scales instances (not modeled)
    - Resolves agent dependency ordering via topological sort (not modeled)
    - Detects zombies (session exists but process dead) (not modeled)
    - Clears session_key metadata on crash (Go-specific recovery)

  COVERAGE: ~30% of reconciler logic. Core quarantine math is accurate.

  Architecture: docs/architecture/health-patrol.md
  Bead: dc-ech
-/

import GasCity.AgentProtocol
import GasCity.EventBus
import GasCity.Config

namespace GasCity.HealthPatrol

/-- Crash history for an agent: list of restart timestamps. -/
structure CrashHistory where
  restarts : List Timestamp
  deriving Repr

/-- Reconciliation config: max restarts within a window. -/
structure PatrolConfig where
  maxRestarts : Nat
  restartWindow : Nat  -- time window in seconds
  deriving Repr

/-- Prune crash history: remove entries older than window. -/
def prune (h : CrashHistory) (now : Timestamp) (window : Nat) : CrashHistory :=
  { restarts := h.restarts.filter (fun ts => now - ts < window) }

/-- Check if agent is quarantined (too many restarts in window). -/
def isQuarantined (h : CrashHistory) (now : Timestamp) (cfg : PatrolConfig) : Bool :=
  let recent := (prune h now cfg.restartWindow).restarts
  recent.length > cfg.maxRestarts

/-- Record a restart in the crash history. -/
def recordRestart (h : CrashHistory) (now : Timestamp) : CrashHistory :=
  { restarts := h.restarts ++ [now] }

/-- Agent reconciliation state. -/
inductive ReconcileAction where
  | skip : ReconcileAction       -- healthy or quarantined
  | start : ReconcileAction      -- not running, should be
  | stopStart : ReconcileAction  -- drifted config
  | stop : ReconcileAction       -- orphan (running, not in desired set)
  deriving DecidableEq, Repr

/-- Determine reconciliation action for a single agent. -/
def reconcileAgent
    (ps : AgentProtocol.ProviderState)
    (name : SessionName)
    (desiredHash : Option String)  -- None = agent not in desired set
    (history : CrashHistory)
    (now : Timestamp)
    (cfg : PatrolConfig) : ReconcileAction :=
  -- Quarantine check first
  if isQuarantined history now cfg then .skip
  else match ps.sessions name, desiredHash with
  | .notRunning, some _ => .start
  | .running currentHash, some desired =>
      if currentHash = desired then .skip else .stopStart
  | .running _, none => .stop
  | .notRunning, none => .skip

/-- Idempotent reconciliation: full pass over all agents. -/
def reconcile
    (ps : AgentProtocol.ProviderState)
    (agents : List (SessionName × String))  -- (name, desired hash)
    (histories : SessionName → CrashHistory)
    (now : Timestamp)
    (cfg : PatrolConfig) :
    List (SessionName × ReconcileAction) :=
  agents.map fun (name, hash) =>
    (name, reconcileAgent ps name (some hash) (histories name) now cfg)

-- ═══════════════════════════════════════════════════════════════
-- Theorems
-- ═══════════════════════════════════════════════════════════════

/-- Quarantine auto-expires: once all restart timestamps age past
    the window, quarantine is lifted. -/
theorem quarantine_auto_expires (h : CrashHistory) (cfg : PatrolConfig)
    (now futureNow : Timestamp)
    (hq : isQuarantined h now cfg = true)
    (hfuture : ∀ ts ∈ h.restarts, futureNow - ts ≥ cfg.restartWindow) :
    isQuarantined h futureNow cfg = false := by
  simp only [isQuarantined, prune]
  -- The filter keeps only timestamps where futureNow - ts < cfg.restartWindow.
  -- But hfuture says futureNow - ts ≥ cfg.restartWindow for ALL ts in h.restarts.
  -- So the filter keeps nothing → length = 0 → ¬(0 > maxRestarts).
  suffices hnil : List.filter (fun ts => decide (futureNow - ts < cfg.restartWindow)) h.restarts = [] by
    simp [hnil]
  have hpred : ∀ ts ∈ h.restarts, decide (futureNow - ts < cfg.restartWindow) = false := by
    intro ts hts
    simp only [decide_eq_false_iff_not, Nat.not_lt]
    exact hfuture ts hts
  -- Induct on the list to show filter returns []
  generalize h.restarts = l at hpred
  induction l with
  | nil => rfl
  | cons a t ih =>
    simp only [List.filter]
    rw [hpred a (List.Mem.head t)]
    exact ih (fun ts hts => hpred ts (List.Mem.tail a hts))

/-- One-for-one restart: applying agent A's reconcile action
    does not change the session state for agent B. -/
theorem one_for_one (ps : AgentProtocol.ProviderState)
    (nameA nameB : SessionName)
    (hne : nameA ≠ nameB)
    (cfg : AgentProtocol.Config) :
    -- Starting A doesn't change B's session
    (AgentProtocol.start ps nameA cfg).1.sessions nameB = ps.sessions nameB ∧
    -- Stopping A doesn't change B's session
    (AgentProtocol.stop ps nameA).sessions nameB = ps.sessions nameB := by
  have hne' : nameB ≠ nameA := Ne.symm hne
  constructor
  · simp [AgentProtocol.start]
    split <;> simp [hne']
  · simp [AgentProtocol.stop, hne']

/-- Reconciliation is idempotent: a healthy agent stays skipped. -/
theorem reconcile_healthy_skip (ps : AgentProtocol.ProviderState)
    (name : SessionName) (hash : String)
    (history : CrashHistory) (now : Timestamp) (cfg : PatrolConfig)
    (hrunning : ps.sessions name = .running hash)
    (hnq : isQuarantined history now cfg = false) :
    reconcileAgent ps name (some hash) history now cfg = .skip := by
  simp [reconcileAgent, hrunning, hnq]

/-- Config drift detected: different hash triggers stopStart. -/
theorem drift_detection (ps : AgentProtocol.ProviderState)
    (name : SessionName) (currentHash desiredHash : String)
    (history : CrashHistory) (now : Timestamp) (cfg : PatrolConfig)
    (hrunning : ps.sessions name = .running currentHash)
    (hdiff : currentHash ≠ desiredHash)
    (hnq : isQuarantined history now cfg = false) :
    reconcileAgent ps name (some desiredHash) history now cfg = .stopStart := by
  simp [reconcileAgent, hrunning, hnq, hdiff]

/-- Crash tracking is bounded: prune removes stale entries. -/
theorem prune_bounded (h : CrashHistory) (now : Timestamp) (window : Nat) :
    (prune h now window).restarts.length ≤ h.restarts.length := by
  simp [prune]
  exact List.length_filter_le _ _

-- TODO: formalize derivation claim as a real theorem
/-- Derivation: Health Patrol uses only P1, P3, P4.
    No new infrastructure beyond three primitives. -/
theorem derivation_from_p1_p3_p4 :
    -- reconcileAgent calls:
    --   AgentProtocol: sessions lookup (P1)
    --   Config: PatrolConfig thresholds (P4)
    --   EventBus: stall publication (P3, implicit in full controller)
    True := by trivial

end GasCity.HealthPatrol
