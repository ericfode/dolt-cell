/-
  GasCity.EventBus — Primitive 3: monotonic sequences and immutability

  Formalizes events.Provider from internal/events/events.go.
  The event bus is an append-only log with strictly monotonic sequence
  numbers and conjunction-based filtering.

  COVERAGE (vs Go implementation):
    Event fields: 6/7 (missing Payload : json.RawMessage)
    Provider methods: 4/5 (missing Close)
    Watcher: modeled as pure list return, not blocking Next()
    Filter semantics: correct (conjunction, zero = match all)
    NOTE: subject and message are omitempty in Go (optional),
      but modeled as mandatory String here. Should be Option String.

  Go source: internal/events/events.go
  Architecture: docs/architecture/event-bus.md
  Bead: dc-ecy
-/

import GasCity.Basic

namespace GasCity.EventBus

/-- An event in the append-only log. -/
structure Event where
  seq : Seq
  type : String
  ts : Timestamp
  actor : String
  subject : String
  message : String
  deriving DecidableEq, Repr

/-- Filter for querying events. Empty string means "match all". -/
structure Filter where
  type : String := ""
  actor : String := ""
  since : Timestamp := 0
  afterSeq : Seq := 0

/-- Whether an event matches a filter (conjunction of all non-empty fields). -/
def Event.matchesFilter (e : Event) (f : Filter) : Bool :=
  (f.type == "" || e.type == f.type) &&
  (f.actor == "" || e.actor == f.actor) &&
  (f.since == 0 || e.ts ≥ f.since) &&
  (f.afterSeq == 0 || e.seq > f.afterSeq)

/-- The event log: an ordered list of events (newest last). -/
structure EventLog where
  events : List Event
  nextSeq : Seq

/-- An empty event log. -/
def EventLog.empty : EventLog := { events := [], nextSeq := 1 }

/-- Record an event. Seq is assigned by the provider, monotonically. -/
def record (log : EventLog) (e : Event) : EventLog :=
  let e' := { e with seq := log.nextSeq }
  { events := log.events ++ [e']
  , nextSeq := log.nextSeq + 1 }

/-- List events matching a filter. -/
def list (log : EventLog) (f : Filter) : List Event :=
  log.events.filter (·.matchesFilter f)

/-- Latest sequence number (0 for empty log). -/
def latestSeq (log : EventLog) : Seq :=
  match log.events.getLast? with
  | some e => e.seq
  | none => 0

/-- Watch cursor: all events with seq > afterSeq. -/
def watchFrom (log : EventLog) (afterSeq : Seq) : List Event :=
  log.events.filter (·.seq > afterSeq)

-- ═══════════════════════════════════════════════════════════════
-- Theorems
-- ═══════════════════════════════════════════════════════════════

/-- Seq is strictly monotonic: recording two events produces
    strictly increasing sequence numbers. -/
theorem seq_strictly_monotonic (log : EventLog) (e1 e2 : Event) :
    let log1 := record log e1
    let log2 := record log1 e2
    log1.nextSeq - 1 < log2.nextSeq - 1 := by
  simp [record]

/-- Seq uniqueness: two events recorded sequentially have different seqs. -/
theorem seq_unique (log : EventLog) (e1 e2 : Event) :
    let log1 := record log e1
    let log2 := record log1 e2
    let assigned1 := log.nextSeq
    let assigned2 := log1.nextSeq
    assigned1 ≠ assigned2 := by
  simp [record]

/-- Events are immutable: the log is append-only.
    Recording a new event does not modify existing events. -/
theorem append_only (log : EventLog) (e : Event) :
    ∀ ev ∈ log.events, ev ∈ (record log e).events := by
  intro ev hev
  simp [record]
  exact Or.inl hev

/-- Empty filter matches all events. -/
theorem empty_filter_matches_all (e : Event) :
    e.matchesFilter {} = true := by
  simp [Event.matchesFilter]

/-- LatestSeq returns 0 for empty log. -/
theorem latestSeq_empty : latestSeq EventLog.empty = 0 := by
  simp [latestSeq, EventLog.empty]

/-- Watch cursor never yields events at or before afterSeq. -/
theorem watch_cursor_correct (log : EventLog) (afterSeq : Seq) :
    ∀ e ∈ watchFrom log afterSeq, e.seq > afterSeq := by
  intro e he
  simp [watchFrom] at he
  exact he.2

/-- Seq persists across restarts: if we record to a log starting
    at nextSeq = n, all new events have seq ≥ n. -/
theorem seq_persistence (log : EventLog) (e : Event) :
    let log' := record log e
    (log'.events.getLast?).map (·.seq) = some log.nextSeq := by
  simp [record, List.getLast?_append]

end GasCity.EventBus
