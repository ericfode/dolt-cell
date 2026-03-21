/-
  GasCity.AgentProtocol — Primitive 1: session lifecycle and idempotence

  Formalizes runtime.Provider from internal/runtime/runtime.go.

  COVERAGE (vs Go implementation):
    Provider methods modeled: 3/15 (Start, Stop, ProcessAlive)
    Missing methods: Interrupt, IsRunning, IsAttached, Attach, Nudge,
      SetMeta, GetMeta, RemoveMeta, Peek, ListRunning, GetLastActivity,
      ClearScrollback, CopyTo, SendKeys, RunLive, Capabilities
    Optional interfaces: 0/3 (InteractionProvider, IdleWaitProvider,
      ImmediateNudgeProvider not modeled)
    Config fields: 5/17 (missing ReadyPromptPrefix, ReadyDelayMs,
      PreStart, SessionSetup, SessionLive, OverlayDir, CopyFiles, etc.)

  The Lean model captures the core Start/Stop lifecycle and idempotence.
  Metadata, interaction, and session observation are not formalized.

  Go source: internal/runtime/runtime.go
  Architecture: docs/architecture/agent-protocol.md
  Bead: dc-non
-/

import GasCity.Basic

namespace GasCity.AgentProtocol

/-- Configuration for starting an agent session. -/
structure Config where
  workDir : String
  command : String
  env : List (String × String)
  processNames : List String
  fingerprintExtra : List String

/-- Content hash of a config, used for drift detection. -/
opaque ConfigFingerprint (cfg : Config) : String

/-- Session state as observed by the provider. -/
inductive SessionState where
  | notRunning : SessionState
  | running : String → SessionState  -- carries fingerprint hash
  deriving DecidableEq

/-- Abstract provider interface.
    We model this as a state transformer on a session map. -/
structure ProviderState where
  sessions : SessionName → SessionState

/-- Start a session. Returns error if already exists. -/
def start (s : ProviderState) (name : SessionName) (cfg : Config) :
    ProviderState × Bool :=
  match s.sessions name with
  | .notRunning => ({ sessions := fun n =>
      if n = name then .running (ConfigFingerprint cfg) else s.sessions n }, true)
  | .running _ => (s, false)

/-- Stop a session. Idempotent: no-op if not running. -/
def stop (s : ProviderState) (name : SessionName) : ProviderState :=
  { sessions := fun n =>
      if n = name then .notRunning else s.sessions n }

/-- ProcessAlive: returns true if processNames is empty. -/
def processAlive (_s : ProviderState) (processNames : List String) : Bool :=
  processNames.isEmpty

-- ═══════════════════════════════════════════════════════════════
-- Theorems
-- ═══════════════════════════════════════════════════════════════

/-- Stop is idempotent: stopping twice is the same as stopping once. -/
theorem stop_idempotent (s : ProviderState) (name : SessionName) :
    stop (stop s name) name = stop s name := by
  simp [stop, ProviderState.mk.injEq]
  funext n
  split <;> simp_all

/-- ProcessAlive returns true for empty process list. -/
theorem processAlive_empty (s : ProviderState) :
    processAlive s [] = true := by
  simp [processAlive]

/-- Starting an already-running session does not change state. -/
theorem start_running_noop (s : ProviderState) (name : SessionName) (cfg : Config)
    (h : String) :
    s.sessions name = .running h →
    (start s name cfg).1 = s := by
  intro hrun
  simp [start, hrun]

/-- Stop then start gives a running session. -/
theorem stop_start_running (s : ProviderState) (name : SessionName) (cfg : Config) :
    let s' := stop s name
    let (s'', ok) := start s' name cfg
    ok = true ∧ s''.sessions name = .running (ConfigFingerprint cfg) := by
  simp [stop, start]

end GasCity.AgentProtocol
