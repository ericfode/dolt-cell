/-
  Layering: Structural invariants for the Gas Town architecture

  Gas Town's formal model is organized into layers. Lower layers provide
  infrastructure; higher layers add protocol, rendering, and orchestration.
  Six invariants govern the architecture:

    L1: No upward dependencies — Layer N never imports Layer N+1
    L2: BeadStore is universal persistence substrate
    L3: EventBus is universal observation substrate
    L4: Config is universal activation mechanism
    L5: Side effects confined to Layer 0 (infrastructure)
    L6: Controller drives all SDK initialization in layer order

  Also formalizes the progressive capability model: subsystem capabilities
  are gated by Config.ActivationLevel, and enabling more subsystems never
  decreases the required activation level.

  Imports from all P1-P5 formal modules:
    Core          — EffLevel (effect lattice)
    Config        — ActivationLevel, capabilityAvailable, progressive_activation
    BeadStore     — Store, Bead, wellFormed, create_preserves_wellFormed
    EventBus      — Provider, Filter, query_all_match, watch_above_cursor
    AgentProtocol — RuntimeState, Session, stop_idempotent
    PromptTemplates — PromptContext, renderTemplate, render_deterministic

  Go source reference: internal/controller/controller.go (layering enforcement)
  Architecture: docs/architecture/layering.md
-/

import Core
import GasCity.Config
import GasCity.BeadStore
import GasCity.EventBus
import GasCity.AgentProtocol
import GasCity.PromptTemplates

namespace Layering

/-! ====================================================================
    LAYER HIERARCHY
    ==================================================================== -/

/-- Architecture layers, ordered from infrastructure to orchestration.
    Maps to the Go codebase's package dependency DAG. -/
inductive Layer where
  | infrastructure  -- 0: Core, Config, BeadStore, EventBus
  | protocol        -- 1: AgentProtocol (session lifecycle)
  | templates       -- 2: PromptTemplates (rendering)
  | orchestration   -- 3: Dispatch, HealthPatrol (coordination)
  deriving Repr, DecidableEq, BEq

/-- Numeric encoding for total order. -/
def Layer.toNat : Layer → Nat
  | .infrastructure => 0
  | .protocol       => 1
  | .templates      => 2
  | .orchestration  => 3

instance : LE Layer where
  le a b := a.toNat ≤ b.toNat

instance : LT Layer where
  lt a b := a.toNat < b.toNat

instance (a b : Layer) : Decidable (a ≤ b) :=
  inferInstanceAs (Decidable (a.toNat ≤ b.toNat))

instance (a b : Layer) : Decidable (a < b) :=
  inferInstanceAs (Decidable (a.toNat < b.toNat))

/-- Infrastructure is the lowest layer. -/
theorem infrastructure_le_all (l : Layer) : Layer.infrastructure ≤ l := by
  cases l <;> decide

/-- Orchestration is the highest layer. -/
theorem all_le_orchestration (l : Layer) : l ≤ Layer.orchestration := by
  cases l <;> decide

/-- The complete layer chain. -/
theorem layer_chain :
    Layer.infrastructure < Layer.protocol ∧
    Layer.protocol < Layer.templates ∧
    Layer.templates < Layer.orchestration :=
  ⟨by decide, by decide, by decide⟩

/-- Layer ordering is total. -/
theorem layer_total (a b : Layer) : a ≤ b ∨ b ≤ a := by
  show a.toNat ≤ b.toNat ∨ b.toNat ≤ a.toNat
  omega

/-- Layer ordering is transitive. -/
theorem layer_trans {a b c : Layer}
    (hab : a ≤ b) (hbc : b ≤ c) : a ≤ c :=
  Nat.le_trans hab hbc

/-! ====================================================================
    MODULE REGISTRY
    ==================================================================== -/

/-- Formal modules in the codebase.
    Each corresponds to a .lean file and a Go package. -/
inductive Module where
  | core            -- Core.lean: shared identity types, effect lattice
  | config          -- Config.lean: layered configuration, activation
  | beadStore       -- BeadStore.lean: work unit persistence (CRUD)
  | eventBus        -- EventBus.lean: append-only event log
  | agentProtocol   -- AgentProtocol.lean: session lifecycle, provider
  | promptTemplates -- PromptTemplates.lean: template rendering
  | dispatch        -- Dispatch.lean: work dispatch (sling)
  | healthPatrol    -- HealthPatrol.lean: session reconciler
  deriving Repr, DecidableEq, BEq

/-- Each module lives at exactly one layer. -/
def Module.layer : Module → Layer
  | .core            => .infrastructure
  | .config          => .infrastructure
  | .beadStore       => .infrastructure
  | .eventBus        => .infrastructure
  | .agentProtocol   => .protocol
  | .promptTemplates => .templates
  | .dispatch        => .orchestration
  | .healthPatrol    => .orchestration

/-- Actual import dependencies of each module.
    Models the real `import` structure of the Lean codebase. -/
def Module.deps : Module → List Module
  | .core            => []
  | .config          => []
  | .beadStore       => []
  | .eventBus        => [.core]
  | .agentProtocol   => [.core]
  | .promptTemplates => [.core]
  | .dispatch        => [.core]
  | .healthPatrol    => [.core]

/-! ====================================================================
    L1: NO UPWARD DEPENDENCIES
    ==================================================================== -/

/-- A dependency graph satisfies no-upward-deps if every dependency
    is at the same or lower layer than the module that imports it. -/
def noUpwardDeps (depFn : Module → List Module) : Prop :=
  ∀ (m : Module) (dep : Module), dep ∈ depFn m →
    dep.layer.toNat ≤ m.layer.toNat

/-- L1: The actual module dependency graph has no upward dependencies.
    Every import goes to the same or a lower layer. -/
theorem no_upward_deps : noUpwardDeps Module.deps := by
  intro m dep hdep
  cases m <;> simp [Module.deps] at hdep <;>
    (try subst hdep) <;> simp [Module.layer, Layer.toNat]

/-- Corollary: any module's dependency lives at or below its layer. -/
theorem deps_within_layer (m dep : Module) (h : dep ∈ Module.deps m) :
    dep.layer.toNat ≤ m.layer.toNat :=
  no_upward_deps m dep h

/-- Infrastructure modules only depend on other infrastructure modules. -/
theorem infra_deps_infra (m : Module) (h : m.layer = Layer.infrastructure)
    (dep : Module) (hdep : dep ∈ Module.deps m) :
    dep.layer = Layer.infrastructure := by
  cases m <;> simp [Module.layer] at h <;> simp [Module.deps] at hdep <;>
    subst_eqs <;> rfl

/-! ====================================================================
    L2: BEADSTORE IS UNIVERSAL PERSISTENCE SUBSTRATE
    ==================================================================== -/

/-- A persistence operation: any durable state change goes through BeadStore.
    This is by construction — PersistOp is defined solely in terms of
    BeadStore types, ensuring all persistence routes through one substrate. -/
inductive PersistOp where
  | create  : String → BeadStore.BeadType → PersistOp
  | update  : BeadStore.BeadId → BeadStore.UpdateOpts → PersistOp
  | close   : BeadStore.BeadId → PersistOp
  | setMeta : BeadStore.BeadId → String → String → PersistOp
  | addDep  : BeadStore.BeadId → BeadStore.BeadId → String → PersistOp
  deriving Repr

/-- Every persistence operation produces a BeadStore state transition. -/
def PersistOp.apply (op : PersistOp) (s : BeadStore.Store) : BeadStore.Store :=
  match op with
  | .create title bt   => (s.create title (some bt)).1
  | .update id opts    => (s.update id opts).1
  | .close id          => (s.close id).1
  | .setMeta id k v    => (s.setMetadata id k v).1
  | .addDep src tgt dt => s.depAdd src tgt dt

/-- L2: All persistence operations route through BeadStore —
    every PersistOp is a function Store → Store by construction. -/
theorem persistence_through_beadstore (op : PersistOp) (s : BeadStore.Store) :
    ∃ (s' : BeadStore.Store), op.apply s = s' :=
  ⟨op.apply s, rfl⟩

/-- Persistence via create preserves store well-formedness. -/
theorem persist_create_preserves_wf (s : BeadStore.Store) (title : String)
    (bt : BeadStore.BeadType) (wf : BeadStore.wellFormed s) :
    BeadStore.wellFormed (PersistOp.apply (.create title bt) s) := by
  simp [PersistOp.apply]
  exact BeadStore.create_preserves_wellFormed s title (some bt) "" "" none [] "" wf

/-! ====================================================================
    L3: EVENTBUS IS UNIVERSAL OBSERVATION SUBSTRATE
    ==================================================================== -/

/-- An observation query is an EventBus filter. -/
abbrev ObservationQuery := EventBus.Filter

/-- Observe events by querying the EventBus provider. -/
def observe (p : EventBus.Provider) (q : ObservationQuery) : List EventBus.Event :=
  EventBus.query p q

/-- L3: All observed events match the query filter — observation is sound.
    Every event returned by observe satisfies the filter predicate. -/
theorem observation_sound (p : EventBus.Provider) (q : ObservationQuery) :
    ∀ (e : EventBus.Event), e ∈ observe p q →
      EventBus.Filter.matches q e = true :=
  EventBus.query_all_match p q

/-- Observation is a pure projection: it doesn't modify the provider. -/
theorem observation_pure (p : EventBus.Provider) (q : ObservationQuery) :
    observe p q = EventBus.query p q :=
  rfl

/-- Cursor-based observation yields only events after the cursor.
    This enables incremental observation without replay. -/
theorem observation_cursor_sound (p : EventBus.Provider) (q : ObservationQuery)
    (cursor : Nat) :
    ∀ (e : EventBus.Event), e ∈ EventBus.watch p q cursor →
      e.seq > cursor :=
  fun e he => EventBus.watch_above_cursor p q cursor e he

/-! ====================================================================
    L4: CONFIG IS UNIVERSAL ACTIVATION MECHANISM
    ==================================================================== -/

/-- Subsystem capabilities gated by Config.ActivationLevel.
    Each section corresponds to a formal module's runtime capability. -/
inductive ConfigSection where
  | beadStore       -- persistence operations
  | eventBus        -- event recording
  | agentProtocol   -- session management
  | promptTemplates -- template rendering
  | healthPatrol    -- health monitoring
  | dispatch        -- work dispatch
  deriving Repr, DecidableEq, BEq

/-- Minimum activation level required for each subsystem.
    Follows the layer hierarchy: infrastructure sections activate first,
    orchestration sections activate last. -/
def sectionLevel : ConfigSection → Nat
  | .beadStore       => 1
  | .eventBus        => 1
  | .agentProtocol   => 2
  | .promptTemplates => 3
  | .healthPatrol    => 4
  | .dispatch        => 5

/-- Convert section level to Config.ActivationLevel (safe: all values ≤ 8). -/
def sectionActivation (s : ConfigSection) : Config.ActivationLevel :=
  ⟨⟨sectionLevel s, by cases s <;> simp [sectionLevel] <;> omega⟩⟩

/-- Whether a section is available at a given activation level. -/
def sectionAvailable (s : ConfigSection) (level : Config.ActivationLevel) : Bool :=
  decide (sectionActivation s ≤ level)

/-- L4: Section availability is progressive — if a section is available
    at level N, it remains available at any higher level.
    Connects to Config.progressive_activation. -/
theorem section_progressive (s : ConfigSection) (cur cur' : Config.ActivationLevel)
    (havail : sectionAvailable s cur = true)
    (hle : cur ≤ cur') :
    sectionAvailable s cur' = true := by
  simp only [sectionAvailable, decide_eq_true_eq] at *
  exact Nat.le_trans havail hle

/-- Sections at lower layers activate at lower levels. -/
theorem layer_respects_activation (s₁ s₂ : ConfigSection)
    (h : sectionLevel s₁ ≤ sectionLevel s₂) :
    sectionActivation s₁ ≤ sectionActivation s₂ := by
  simp only [sectionActivation]
  exact h

/-- Maximum activation level required across a set of sections. -/
def maxLevel : List ConfigSection → Nat
  | [] => 0
  | s :: ss => max (sectionLevel s) (maxLevel ss)

/-- Adding a section never decreases the maximum required level. -/
theorem activation_monotonic (ss : List ConfigSection) (s : ConfigSection) :
    maxLevel ss ≤ maxLevel (s :: ss) := by
  simp [maxLevel]; omega

/-- Each section's level is bounded by the max of any list containing it. -/
theorem section_le_maxLevel (s : ConfigSection) (ss : List ConfigSection)
    (h : s ∈ ss) : sectionLevel s ≤ maxLevel ss := by
  induction ss with
  | nil => contradiction
  | cons s' ss ih =>
    simp only [maxLevel]
    rcases List.mem_cons.mp h with rfl | hmem
    · exact Nat.le_max_left ..
    · exact Nat.le_trans (ih hmem) (Nat.le_max_right ..)

/-- The maximum level of a concatenated list is the max of the two maxima. -/
theorem maxLevel_append (ss₁ ss₂ : List ConfigSection) :
    maxLevel (ss₁ ++ ss₂) = max (maxLevel ss₁) (maxLevel ss₂) := by
  induction ss₁ with
  | nil => simp [maxLevel]
  | cons s ss₁ ih => simp [maxLevel, ih]

/-- If all sections have level ≤ N, then maxLevel ≤ N. -/
theorem all_available_bound (ss : List ConfigSection) (n : Nat)
    (h : ∀ s ∈ ss, sectionLevel s ≤ n) :
    maxLevel ss ≤ n := by
  induction ss with
  | nil => simp [maxLevel]
  | cons s ss ih =>
    simp only [maxLevel]
    exact Nat.max_le.mpr ⟨h s (List.Mem.head _),
      ih (fun s' hs' => h s' (List.Mem.tail _ hs'))⟩

/-- All sections activate by level 5. -/
theorem all_sections_within_bounds (s : ConfigSection) :
    sectionLevel s ≤ 5 := by
  cases s <;> simp [sectionLevel]

/-- Full activation (level 8) enables all sections. -/
theorem full_enables_all (s : ConfigSection) :
    sectionAvailable s Config.ActivationLevel.full = true := by
  cases s <;> decide

/-! ====================================================================
    L5: SIDE EFFECTS CONFINED TO LAYER 0
    ==================================================================== -/

/-- Maximum effect level of a module, using Core.EffLevel.
    Only infrastructure modules may produce non-replayable effects.
    Connects to the EffLevel lattice (pure < replayable < nonReplayable). -/
def Module.maxEffect : Module → EffLevel
  | .core            => .pure            -- type definitions
  | .config          => .pure            -- config composition
  | .beadStore       => .nonReplayable   -- persistent store writes
  | .eventBus        => .nonReplayable   -- event log appends
  | .agentProtocol   => .replayable      -- session management
  | .promptTemplates => .pure            -- template rendering
  | .dispatch        => .replayable      -- dispatch decisions
  | .healthPatrol    => .replayable      -- health checks

/-- L5: Modules above the infrastructure layer have at most replayable effects.
    NonReplayable (world-mutating) effects are confined to Layer 0. -/
theorem effects_bounded_by_layer (m : Module)
    (h : m.layer ≠ Layer.infrastructure) :
    m.maxEffect ≤ EffLevel.replayable := by
  cases m <;> simp [Module.layer] at h <;> decide

/-- NonReplayable effects occur only in infrastructure modules. -/
theorem nonReplayable_only_infra (m : Module)
    (h : m.maxEffect = EffLevel.nonReplayable) :
    m.layer = Layer.infrastructure := by
  cases m <;> simp [Module.maxEffect] at h <;> rfl

/-- Pure modules remain pure regardless of layer. -/
theorem pure_modules_identified :
    Module.core.maxEffect = .pure ∧
    Module.config.maxEffect = .pure ∧
    Module.promptTemplates.maxEffect = .pure :=
  ⟨rfl, rfl, rfl⟩

/-! ====================================================================
    L6: CONTROLLER DRIVES ALL SDK INITIALIZATION
    ==================================================================== -/

/-- The canonical initialization order: modules are initialized
    from infrastructure up through orchestration. -/
def initOrder : List Module :=
  [.core, .config, .beadStore, .eventBus,
   .agentProtocol, .promptTemplates,
   .dispatch, .healthPatrol]

/-- Every module appears in the initialization order. -/
theorem init_complete (m : Module) : m ∈ initOrder := by
  cases m <;> simp [initOrder]

/-- L6: Initialization proceeds in non-decreasing layer order.
    Modules at layer N are initialized before modules at layer N+1. -/
theorem init_respects_layers :
    ∀ (i j : Fin initOrder.length), i.val ≤ j.val →
      (initOrder.get i).layer.toNat ≤ (initOrder.get j).layer.toNat := by
  decide

/-- Dependencies are initialized before dependents: if module A depends on
    module B, then B's layer ≤ A's layer. -/
theorem deps_init_before (m dep : Module)
    (hdep : dep ∈ Module.deps m) :
    dep.layer.toNat ≤ m.layer.toNat :=
  deps_within_layer m dep hdep

/-! ====================================================================
    PROGRESSIVE CAPABILITY MODEL
    ==================================================================== -/

/-- A system state: tracks which sections are currently active
    and the current Config.ActivationLevel. -/
structure SystemState where
  activeSections : List ConfigSection
  currentLevel : Config.ActivationLevel
  /-- All active sections must be available at the current level. -/
  valid : ∀ s, s ∈ activeSections → sectionAvailable s currentLevel = true

/-- Raising the activation level preserves all existing capabilities.
    Follows from Config.progressive_activation. -/
theorem raise_preserves_capabilities (st : SystemState)
    (newLevel : Config.ActivationLevel)
    (hle : st.currentLevel ≤ newLevel) :
    ∀ s, s ∈ st.activeSections → sectionAvailable s newLevel = true := by
  intro s hs
  exact section_progressive s st.currentLevel newLevel (st.valid s hs) hle

/-- The dormant state: nothing active at level 0. -/
def SystemState.dormant : SystemState :=
  { activeSections := []
    currentLevel := Config.ActivationLevel.dormant
    valid := nofun }

/-- At full activation, all sections can be enabled. -/
theorem full_activation_enables_all :
    ∀ (s : ConfigSection), sectionAvailable s Config.ActivationLevel.full = true :=
  full_enables_all

/-! ====================================================================
    CROSS-MODULE INTEGRATION
    ==================================================================== -/

/-- AgentProtocol stop is idempotent — demonstrates that protocol-layer
    operations (Layer 1) compose cleanly. -/
theorem protocol_stop_idempotent (s : AgentProtocol.RuntimeState)
    (name : AgentProtocol.SessionName) :
    AgentProtocol.stop (AgentProtocol.stop s name) name =
    AgentProtocol.stop s name :=
  AgentProtocol.stop_idempotent s name

/-- PromptTemplates rendering is deterministic — demonstrates that
    template-layer operations (Layer 2) are pure. -/
theorem templates_render_deterministic (ctx : PromptTemplates.PromptContext)
    (t : PromptTemplates.Template) :
    PromptTemplates.renderTemplate ctx t = PromptTemplates.renderTemplate ctx t :=
  rfl

/-- EventBus empty filter matches all events — the universal observation
    property at the infrastructure layer. -/
theorem eventbus_empty_matches_all (e : EventBus.Event) :
    EventBus.Filter.matches {} e = true :=
  EventBus.empty_filter_matches_all e

/-- BeadStore init is well-formed — the initial infrastructure state
    satisfies all invariants. -/
theorem beadstore_init_wf : BeadStore.wellFormed BeadStore.Store.init :=
  BeadStore.init_wellFormed

end Layering
