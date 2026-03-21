/-
  Config: Formal Model of Gas Town Configuration

  Gas Town's configuration system composes layered files into a
  deterministic City structure. Agents are identified by unique
  (Dir, Name) pairs. Rigs have unique prefixes. Configuration
  entries follow strict override precedence.

  Properties formalized:
    P1: Agent identity uniqueness — no two agents share (Dir, Name)
    P2: Rig prefix uniqueness — no two rigs share a prefix
    P3: Deterministic composition — identical inputs → identical City
    P4: Patch application idempotence
    P5: Override precedence — builtin < city < workspace < per-agent
    P6: Revision immutability — hash changes iff content changes
    P7: Pack layer ordering — city-packs < city-local < rig-packs < rig-local
    P8: Progressive activation levels 0-8
-/

namespace Config

/-! ====================================================================
    IDENTITY TYPES
    ==================================================================== -/

/-- Agent directory path within a rig. -/
structure AgentDir where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

/-- Agent name within its directory. -/
structure AgentName where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

/-- Agent identity: unique (Dir, Name) pair. -/
structure AgentId where
  dir : AgentDir
  name : AgentName
  deriving Repr, DecidableEq, BEq

/-- Rig prefix: unique per rig within a city. -/
structure RigPrefix where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

/-! ====================================================================
    LAWFUL BEQ INSTANCES
    ==================================================================== -/

instance : LawfulBEq AgentDir where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

instance : LawfulBEq AgentName where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

instance : LawfulBEq RigPrefix where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

/-! ====================================================================
    P5: OVERRIDE PRECEDENCE — builtin < city < workspace < per-agent
    ==================================================================== -/

/-- Config layers, ordered by override precedence.
    Each layer can override values set by lower layers. -/
inductive ConfigLayer where
  | builtin    -- factory defaults shipped with the binary
  | city       -- city-level settings (settings.json)
  | workspace  -- workspace-level overrides
  | perAgent   -- per-agent overrides (highest precedence)
  deriving Repr, DecidableEq, BEq

/-- Numeric encoding for total order. -/
def ConfigLayer.toNat : ConfigLayer → Nat
  | .builtin   => 0
  | .city      => 1
  | .workspace => 2
  | .perAgent  => 3

instance : LE ConfigLayer where
  le a b := a.toNat ≤ b.toNat

instance : LT ConfigLayer where
  lt a b := a.toNat < b.toNat

instance (a b : ConfigLayer) : Decidable (a ≤ b) :=
  inferInstanceAs (Decidable (a.toNat ≤ b.toNat))

instance (a b : ConfigLayer) : Decidable (a < b) :=
  inferInstanceAs (Decidable (a.toNat < b.toNat))

/-- Builtin is the lowest precedence layer. -/
theorem builtin_le_all (l : ConfigLayer) : ConfigLayer.builtin ≤ l := by
  cases l <;> decide

/-- Per-agent is the highest precedence layer. -/
theorem all_le_perAgent (l : ConfigLayer) : l ≤ ConfigLayer.perAgent := by
  cases l <;> decide

/-- P5: The complete precedence chain. -/
theorem precedence_chain :
    ConfigLayer.builtin < ConfigLayer.city ∧
    ConfigLayer.city < ConfigLayer.workspace ∧
    ConfigLayer.workspace < ConfigLayer.perAgent :=
  ⟨by decide, by decide, by decide⟩

/-- Layer ordering is total. -/
theorem configLayer_total (a b : ConfigLayer) : a ≤ b ∨ b ≤ a := by
  show a.toNat ≤ b.toNat ∨ b.toNat ≤ a.toNat
  omega

/-- Layer ordering is transitive. -/
theorem configLayer_trans {a b c : ConfigLayer}
    (hab : a ≤ b) (hbc : b ≤ c) : a ≤ c :=
  Nat.le_trans hab hbc

/-- Layer ordering is antisymmetric. -/
theorem configLayer_antisymm {a b : ConfigLayer}
    (hab : a ≤ b) (hba : b ≤ a) : a = b := by
  have h : a.toNat = b.toNat := Nat.le_antisymm hab hba
  cases a <;> cases b <;> simp_all [ConfigLayer.toNat]

/-- toNat is injective: distinct layers have distinct codes. -/
theorem configLayer_toNat_injective {a b : ConfigLayer}
    (h : a.toNat = b.toNat) : a = b := by
  cases a <;> cases b <;> simp_all [ConfigLayer.toNat]

/-! ====================================================================
    P7: PACK LAYER ORDERING
    ==================================================================== -/

/-- Pack layers determine search/load order for pack resolution. -/
inductive PackLayer where
  | cityPacks   -- shared packs distributed at city level
  | cityLocal   -- city-local overrides to packs
  | rigPacks    -- rig-specific packs
  | rigLocal    -- rig-local overrides (highest priority)
  deriving Repr, DecidableEq, BEq

/-- Numeric encoding for total order. -/
def PackLayer.toNat : PackLayer → Nat
  | .cityPacks => 0
  | .cityLocal => 1
  | .rigPacks  => 2
  | .rigLocal  => 3

instance : LE PackLayer where
  le a b := a.toNat ≤ b.toNat

instance : LT PackLayer where
  lt a b := a.toNat < b.toNat

instance (a b : PackLayer) : Decidable (a ≤ b) :=
  inferInstanceAs (Decidable (a.toNat ≤ b.toNat))

instance (a b : PackLayer) : Decidable (a < b) :=
  inferInstanceAs (Decidable (a.toNat < b.toNat))

/-- P7: The complete pack layer ordering. -/
theorem packLayer_chain :
    PackLayer.cityPacks < PackLayer.cityLocal ∧
    PackLayer.cityLocal < PackLayer.rigPacks ∧
    PackLayer.rigPacks < PackLayer.rigLocal :=
  ⟨by decide, by decide, by decide⟩

/-- Pack layer ordering is total. -/
theorem packLayer_total (a b : PackLayer) : a ≤ b ∨ b ≤ a := by
  show a.toNat ≤ b.toNat ∨ b.toNat ≤ a.toNat
  omega

/-- Pack layer ordering is transitive. -/
theorem packLayer_trans {a b c : PackLayer}
    (hab : a ≤ b) (hbc : b ≤ c) : a ≤ c :=
  Nat.le_trans hab hbc

/-! ====================================================================
    P8: PROGRESSIVE ACTIVATION LEVELS 0-8
    ==================================================================== -/

/-- Activation level: 0 (dormant) through 8 (full capabilities).
    Progressive: activating to level N enables all capabilities ≤ N. -/
structure ActivationLevel where
  val : Fin 9
  deriving Repr, DecidableEq, BEq

instance : LE ActivationLevel where
  le a b := a.val.val ≤ b.val.val

instance (a b : ActivationLevel) : Decidable (a ≤ b) :=
  inferInstanceAs (Decidable (a.val.val ≤ b.val.val))

/-- Level 0: dormant — no capabilities enabled. -/
def ActivationLevel.dormant : ActivationLevel := ⟨⟨0, by omega⟩⟩

/-- Level 8: full — all capabilities enabled. -/
def ActivationLevel.full : ActivationLevel := ⟨⟨8, by omega⟩⟩

/-- Dormant is the minimum activation level. -/
theorem dormant_le_all (l : ActivationLevel) : ActivationLevel.dormant ≤ l := by
  show (0 : Nat) ≤ l.val.val
  omega

/-- Full is the maximum activation level. -/
theorem all_le_full (l : ActivationLevel) : l ≤ ActivationLevel.full := by
  show l.val.val ≤ 8
  have := l.val.isLt
  omega

/-- Whether a capability at a required level is available given current level. -/
def capabilityAvailable (required current : ActivationLevel) : Bool :=
  decide (required ≤ current)

/-- P8: Progressive activation — capabilities available at level N
    remain available at any higher level. -/
theorem progressive_activation (req cur cur' : ActivationLevel)
    (havail : capabilityAvailable req cur = true)
    (hle : cur ≤ cur') :
    capabilityAvailable req cur' = true := by
  simp only [capabilityAvailable, decide_eq_true_eq] at *
  exact Nat.le_trans havail hle

/-! ====================================================================
    P6: REVISION IMMUTABILITY
    ==================================================================== -/

/-- Content hash for revision tracking. -/
structure ContentHash where
  val : Nat
  deriving Repr, DecidableEq, BEq

/-- An injective hash function from content to its hash.
    Injectivity ensures revision immutability. -/
structure HashFn where
  hash : String → ContentHash
  injective : ∀ (a b : String), hash a = hash b → a = b

/-- A revision: content paired with its deterministic hash. -/
structure Revision (hf : HashFn) where
  content : String
  contentHash : ContentHash
  consistent : hf.hash content = contentHash

/-- P6: Revision immutability — hash changes if and only if content changes.
    Same content → same hash (determinism), different content → different hash
    (injectivity). -/
theorem revision_immutability (hf : HashFn)
    (r1 r2 : Revision hf) :
    r1.contentHash = r2.contentHash ↔ r1.content = r2.content := by
  constructor
  · intro h
    apply hf.injective
    rw [r1.consistent, r2.consistent]
    exact h
  · intro h
    rw [← r1.consistent, ← r2.consistent, h]

/-! ====================================================================
    CONFIG MAP AND PATCH APPLICATION
    ==================================================================== -/

/-- A configuration map: partial function from keys to values. -/
abbrev ConfigMap := String → Option String

/-- Empty configuration. -/
def ConfigMap.empty : ConfigMap := fun _ => none

/-- Apply a patch: for each key defined in the patch, override the config
    value. Keys not in the patch retain their original values. -/
def applyPatch (config patch : ConfigMap) : ConfigMap :=
  fun key => match patch key with
  | some v => some v
  | none => config key

/-- P4: Patch application is idempotent — applying the same patch twice
    gives the same result as applying it once. -/
theorem patch_idempotent (config patch : ConfigMap) :
    applyPatch (applyPatch config patch) patch = applyPatch config patch := by
  funext key
  simp only [applyPatch]
  split <;> rfl

/-- Patching with the empty map is a no-op. -/
theorem patch_empty (config : ConfigMap) :
    applyPatch config ConfigMap.empty = config := by
  funext key
  simp [applyPatch, ConfigMap.empty]

/-- Patching preserves values for keys not in the patch. -/
theorem patch_preserves (config patch : ConfigMap) (key : String)
    (h : patch key = none) :
    applyPatch config patch key = config key := by
  simp [applyPatch, h]

/-- Patching overrides values for keys in the patch. -/
theorem patch_overrides (config patch : ConfigMap) (key : String) (v : String)
    (h : patch key = some v) :
    applyPatch config patch key = some v := by
  simp [applyPatch, h]

/-! ====================================================================
    P5 (BEHAVIORAL): LAYERED COMPOSITION AND OVERRIDE
    ==================================================================== -/

/-- Compose four config layers in precedence order:
    builtin < city < workspace < perAgent. -/
def composeLayers (builtin city workspace perAgent : ConfigMap) : ConfigMap :=
  applyPatch (applyPatch (applyPatch builtin city) workspace) perAgent

/-- Per-agent values override all lower layers. -/
theorem perAgent_overrides_all
    (builtin city workspace perAgent : ConfigMap)
    (key : String) (v : String) (h : perAgent key = some v) :
    composeLayers builtin city workspace perAgent key = some v := by
  simp [composeLayers, applyPatch, h]

/-- Workspace values override builtin and city when per-agent has no value. -/
theorem workspace_overrides_lower
    (builtin city workspace perAgent : ConfigMap)
    (key : String) (v : String)
    (hwk : workspace key = some v) (hpa : perAgent key = none) :
    composeLayers builtin city workspace perAgent key = some v := by
  simp [composeLayers, applyPatch, hwk, hpa]

/-- City values override builtin when workspace and per-agent have no value. -/
theorem city_overrides_builtin
    (builtin city workspace perAgent : ConfigMap)
    (key : String) (v : String)
    (hci : city key = some v) (hwk : workspace key = none)
    (hpa : perAgent key = none) :
    composeLayers builtin city workspace perAgent key = some v := by
  simp [composeLayers, applyPatch, hci, hwk, hpa]

/-- Builtin values are used when no higher layer defines the key. -/
theorem builtin_fallback
    (builtin city workspace perAgent : ConfigMap)
    (key : String) (v : String)
    (hbu : builtin key = some v)
    (hci : city key = none) (hwk : workspace key = none)
    (hpa : perAgent key = none) :
    composeLayers builtin city workspace perAgent key = some v := by
  simp [composeLayers, applyPatch, hbu, hci, hwk, hpa]

/-! ====================================================================
    CITY STRUCTURE AND WELL-FORMEDNESS (P1, P2)
    ==================================================================== -/

/-- An agent registration within a rig. -/
structure AgentReg where
  id : AgentId
  activation : ActivationLevel
  deriving Repr

/-- A rig registration within a city. -/
structure RigReg where
  pfx : RigPrefix
  agents : List AgentReg
  deriving Repr

/-- The top-level city configuration. -/
structure City where
  rigs : List RigReg
  config : ConfigMap

/-- P1: Within a rig, no two agents share an identity (Dir, Name pair). -/
def rigAgentsUnique (rig : RigReg) : Prop :=
  ∀ (i j : Fin rig.agents.length),
    (rig.agents.get i).id = (rig.agents.get j).id → i = j

/-- P2: No two rigs in a city share a prefix. -/
def rigPrefixesUnique (city : City) : Prop :=
  ∀ (i j : Fin city.rigs.length),
    (city.rigs.get i).pfx = (city.rigs.get j).pfx → i = j

/-- A well-formed city satisfies both uniqueness invariants. -/
structure CityWellFormed (city : City) : Prop where
  agentsUnique : ∀ (r : RigReg), r ∈ city.rigs → rigAgentsUnique r
  prefixesUnique : rigPrefixesUnique city

/-- P1 extraction: In a well-formed city, agent IDs are unique per rig. -/
theorem agent_identity_unique (city : City) (wf : CityWellFormed city)
    (r : RigReg) (hr : r ∈ city.rigs)
    (i j : Fin r.agents.length)
    (h : (r.agents.get i).id = (r.agents.get j).id) : i = j :=
  wf.agentsUnique r hr i j h

/-- P2 extraction: In a well-formed city, rig prefixes are unique. -/
theorem rig_prefix_unique (city : City) (wf : CityWellFormed city)
    (i j : Fin city.rigs.length)
    (h : (city.rigs.get i).pfx = (city.rigs.get j).pfx) : i = j :=
  wf.prefixesUnique i j h

/-! ====================================================================
    P3: DETERMINISTIC COMPOSITION
    ==================================================================== -/

/-- Compose a city from layer functions and rig registrations. -/
def compose (layers : ConfigLayer → ConfigMap) (rigs : List RigReg) : City :=
  { rigs := rigs
    config := composeLayers (layers .builtin) (layers .city)
                            (layers .workspace) (layers .perAgent) }

/-- P3: Deterministic composition — identical inputs always produce
    identical city configurations. This is inherent in Lean's function
    model: pure functions are deterministic by construction. -/
theorem deterministic_composition
    (layers₁ layers₂ : ConfigLayer → ConfigMap) (rigs₁ rigs₂ : List RigReg)
    (hl : layers₁ = layers₂) (hr : rigs₁ = rigs₂) :
    compose layers₁ rigs₁ = compose layers₂ rigs₂ := by
  subst hl; subst hr; rfl

end Config
