/-
  GasCity.Messaging — Formal model of the Gas City mail/nudge system

  Formalizes the two-tier messaging system:
  - Mail: durable bead-backed messages (full Dolt commit)
  - Nudge: ephemeral, zero-overhead signals

  Go source: internal/mail/, cmd/gc/nudge.go
  Architecture: docs/architecture/messaging.md

  TODO: Expand with routing invariants, mailbox FIFO ordering,
        nudge idempotence, and archival lifecycle.
-/

import GasCity.Basic

namespace GasCity.Messaging

/-! ====================================================================
    IDENTITY TYPES
    ==================================================================== -/

/-- A mail message ID. -/
abbrev MailId := String

/-- Messaging tier: durable mail or ephemeral nudge. -/
inductive MsgTier where
  | mail   -- permanent, creates a bead
  | nudge  -- ephemeral, no bead
  deriving Repr, DecidableEq

/-- Delivery address: "rig/role" or "rig/role-N". -/
structure Address where
  val : String
  deriving Repr, DecidableEq

/-! ====================================================================
    MAIL MESSAGE
    ==================================================================== -/

structure MailMsg where
  id      : MailId
  sender  : Address
  dest    : Address
  subject : String
  body    : String
  status  : Status  -- open = unread, closed = archived
  deriving Repr

/-! ====================================================================
    MAILBOX STATE
    ==================================================================== -/

structure Mailbox where
  messages : MailId → Option MailMsg
  nextId   : Nat

/-- Empty mailbox. -/
def Mailbox.empty : Mailbox :=
  { messages := fun _ => none, nextId := 0 }

/-! ====================================================================
    INVARIANTS
    ==================================================================== -/

/-- Deliver adds the message to the mailbox. -/
theorem deliver_adds (mb : Mailbox) (msg : MailMsg) (id : MailId) :
    let id' := s!"mail-{mb.nextId}"
    let mb' := { mb with
      messages := fun n => if n = id' then some { msg with id := id' } else mb.messages n
      nextId := mb.nextId + 1 }
    mb'.messages id' ≠ none := by
  simp

end GasCity.Messaging
