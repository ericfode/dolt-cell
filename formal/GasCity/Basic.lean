/-
  GasCity.Basic — shared types for Gas City formalization

  This file defines the core vocabulary: identifiers, status values,
  timestamps, and the effect/layer structure that the nine concepts
  depend on.

  Reference: github.com/gastownhall/gascity CLAUDE.md + nine-concepts.md
-/

namespace GasCity

/-- Layer in the Gas City architecture. Primitives are Layer01,
    derived mechanisms are Layer2 through Layer4. -/
inductive Layer where
  | layer01 : Layer   -- Agent Protocol, Beads, Events, Config, Prompts
  | layer2  : Layer   -- Messaging
  | layer3  : Layer   -- Formulas & Molecules, Dispatch
  | layer4  : Layer   -- Health Patrol
  deriving DecidableEq, Repr

/-- A bead status. The store normalizes all statuses to this three-value set. -/
inductive Status where
  | open        : Status
  | in_progress : Status
  | closed      : Status
  deriving DecidableEq, Repr

/-- A bead type. -/
inductive BeadType where
  | task     : BeadType
  | bug      : BeadType
  | epic     : BeadType
  | chore    : BeadType
  | molecule : BeadType
  | wisp     : BeadType
  | convoy   : BeadType
  | message  : BeadType
  deriving DecidableEq, Repr

/-- Whether a bead type is a container type (can hold children). -/
def BeadType.isContainer : BeadType → Bool
  | .convoy => true
  | .epic   => true
  | _       => false

/-- Unique bead identifier. -/
abbrev BeadId := String

/-- Unique agent session name. -/
abbrev SessionName := String

/-- Monotonically increasing event sequence number. -/
abbrev Seq := Nat

/-- Simplified timestamp (natural number for ordering). -/
abbrev Timestamp := Nat

/-- A label is just a string. Labels form a set that only grows. -/
abbrev Label := String

/-- Progressive capability level (0-8). -/
structure CapLevel where
  level : Fin 9
  deriving DecidableEq, Repr

end GasCity
