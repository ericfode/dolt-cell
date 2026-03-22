/-
  GasCity.Basic — Shared type definitions for the GasCity formal model

  Re-exports Core types (CellName, EffLevel, etc.) so GasCity modules
  can import a single GasCity.Basic instead of reaching into cell-language Core.
-/

import Core

/-! ====================================================================
    GASCITY PRIMITIVE TYPES
    (types used across multiple GasCity modules)
    ==================================================================== -/

/-- A bead identifier (opaque string). -/
abbrev BeadId := String

/-- A bead label tag. -/
abbrev Label := String

/-- Timestamp (Unix seconds). -/
abbrev Timestamp := Nat

/-- Bead status. -/
inductive Status where
  | open
  | closed
  deriving Repr, DecidableEq, BEq

/-- Bead type tag. -/
abbrev BeadType := String
