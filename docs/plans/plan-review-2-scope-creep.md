# Plan Review Round 2: Scope-Creep Analysis

**Reviewer:** emerald (polecat)
**Date:** 2026-03-17
**Bead:** do-aub
**Documents reviewed:**
- `design-data.md` (jade) — data dimension
- `design-security.md` (ruby) — security dimension
- `design-scale.md` (pearl) — scale dimension
- `design-integration.md` (shale) — Gas Town integration dimension
- `design-api.md` (agate) — API dimension
- `design-ux.md` (mica) — UX dimension
- `prd-review-integration.md` (mica) — integration review
- `prd-review-user-experience.md` (agate) — UX review

---

## What is "Next Phase"?

The Cell next phase has a clear core mission: **complete the frame migration
and fix Lean-to-Go conformance bugs**. This was established by the bug-fix
analysis (do-7i1), which identified 25 conformance bugs, 13 of which are
resolved by re-keying from `cell_id` to `frame_id`. The phased migration
(additive → backfill → cutover → cleanup) is the backbone.

Everything in the plan should serve this mission or be explicitly deferred.
The scope-creep patterns below identify work that exceeds this boundary.

---

## Finding 1: Gas Town Integration is Premature (design-integration.md)

**Severity: HIGH — entire document is out of scope for next phase**

The integration dimension designs:
- Event trigger system with a `cell_triggers` table in the beads database
- Completion protocol with structured `_completion` cell conventions
- Cross-program composition (3 patterns: sequential pour, shared SQL, cross-program givens)
- 7-command `gt cell` CLI surface (`pour`, `run`, `status`, `watch`, `yields`, `trigger`, `triggers`)
- Piston-as-agent identity mapping
- 9-phase implementation sequence (v0.1 through v2.1)

All of this assumes the frame migration is **complete and stable**. The
integration document even acknowledges dependencies:

> v0.1: `gt cell pour` and `gt cell status` — **depends on: frame migration complete**

Building a Gas Town integration layer while the underlying data model is
still being migrated is premature. The trigger table, completion protocol,
and cross-program composition patterns should be designed after the frame
model stabilizes, not before.

**Recommendation:** Extract to a separate future design bead. Keep only
the schema-epoch mechanism (Section 7), which is needed for the migration
itself. Everything else (triggers, completion beads, cross-program
composition, `gt cell` commands) is post-migration work.

---

## Finding 2: `ct thaw` Designed Inconsistently Across Two Documents

**Severity: MEDIUM — conflicting implementations will cause rework**

Both `design-api.md` (Section 1.3) and `design-ux.md` (Section 1) design
`ct thaw`, but with fundamentally different semantics:

| Aspect | design-api.md | design-ux.md |
|--------|--------------|-------------|
| Mechanism | DELETE yields + DELETE bindings + UPDATE cells.state | CREATE new frame at gen+1 (append-only) |
| Formal model | Explicit deviation (violates yieldsPreserved) | Composes createFrame (already proven) |
| Old data | Destroyed | Preserved |
| Downstream cells | Cascading thaw (recursive) | Unaffected (--cascade is opt-in) |

The design-ux.md approach (new frame) is more aligned with the formal model
and append-only semantics. The design-api.md approach (delete yields) directly
contradicts the very invariants the frame migration is trying to enforce.

**Recommendation:** Adopt the design-ux.md approach (create new frame).
Remove the conflicting implementation from design-api.md. Defer `ct thaw`
entirely to post-migration — it cannot be implemented until `frame_id` is
the primary key on yields (design-ux.md acknowledges this).

---

## Finding 3: Security Recommendations Overreach (design-security.md)

**Severity: MEDIUM — dilutes focus across 17 recommendations**

The security document identifies 5 gaps and proposes 17 recommendations across
4 sections. The priority matrix itself is well-organized (P0 through P3), but
the P0 items alone already form a substantial work package:

- R2.1: Migrate piston to ct-only interface (Medium effort)
- R1.4: Parameterize all SQL in stored procedures (Medium effort)

These are legitimate next-phase work. But the document also designs:

| Recommendation | What it adds | Why it's scope-creep |
|---------------|-------------|---------------------|
| R1.2 | Per-program SELECT views | Requires program-scoped database views — new infrastructure |
| R2.2 | Restricted Dolt user with fine-grained GRANTs | Dolt's GRANT support is acknowledged as "evolving" |
| R3.1 | `<DATA>` tag wrapping for prompt injection defense | Prompt engineering, not security infrastructure |
| R4.3 | Tamper-resistant epoch (4 options including ed25519 signing) | Document says "overkill for current threat model" |
| R4.4 | Durable reset tracking with new `epoch_log` table | New table for audit completeness |
| R4.5 | Procedure version pinning with SHA256 hash | Nice-to-have, not blocking |

The document also introduces a `schema_metadata` table (Section 4) that
overlaps with `retort_meta` from design-data.md. Two documents are designing
metadata tables independently.

**Recommendation:** Keep R2.1 (ct-only piston) and R1.4 (parameterized SQL)
as next-phase work. Move everything P2+ to a separate security-hardening bead.
Reconcile `schema_metadata` vs `retort_meta` — these should be one table.

---

## Finding 4: Scale Optimizations Before Correctness (design-scale.md)

**Severity: LOW — well-prioritized internally, but overscoped overall**

The scale document's P0 items are correctly identified:
- S1.1: Eliminate claim-phase DOLT_COMMIT (pure win, low effort)
- S4.1: Scope resolveInputs to latest generation (fixes O(G) bug)
- S4.2: Yield UNIQUE index migration (required by frame migration)

These belong in the next phase. However, the document also designs:

- **S2.1: In-memory ReadySet** — a new Go subsystem with dependency graph,
  `sync.Mutex`, and event-driven invalidation. This is a significant
  architecture addition that should be validated after the frame model
  stabilizes, not designed alongside it.
- **S4.3: Frame compaction** — adds a `compacted` boolean column to `frames`.
  The frame migration hasn't landed yet; adding compaction to the same table
  being migrated adds risk.
- **S4.4: claim_log rotation** — operational concern for production workloads
  that don't exist yet.
- **Metrics section** — 5 new metrics to instrument. Instrumentation should
  follow stabilization.

**Recommendation:** Keep S1.1, S4.1, and S4.2 in scope. Defer S2.1 (ReadySet),
S4.3 (compaction), S4.4 (rotation), and metrics to a post-migration
performance bead.

---

## Finding 5: Feature Proliferation in API Surface (design-api.md + design-ux.md)

**Severity: MEDIUM — new commands multiply integration surface during migration**

The next phase adds 6+ new commands or subcommands:

| New command | Source | Depends on |
|-------------|--------|-----------|
| `ct version` | design-api.md | retort_meta table |
| `ct thaw` | design-api.md + design-ux.md | Frame migration complete |
| `ct thaw --cascade` | design-ux.md | ct thaw |
| `ct yield <prog> <cell>.<field>` | design-ux.md | Nothing |
| `ct convergence` | design-ux.md | Frame migration complete |
| `ct help workflow\|syntax` | design-ux.md | Nothing |

Plus 7 new `gt cell` commands from design-integration.md (Finding 1).

The frame migration itself already requires modifying `ct submit`, `ct pour`,
`ct status`, `ct watch`, and `ct piston`. Changing existing commands AND adding
new ones simultaneously increases the risk that the migration introduces
regressions in the CLI surface.

The `ct help` and `ct yield` commands (P0 in design-ux.md) have no migration
dependency and are low-risk additions. The rest should wait.

**Recommendation:** Next phase should add only `ct version` (needed for
schema epoch) and optionally `ct yield` + `ct help` (zero migration
dependency, low risk). Defer `ct thaw`, `ct convergence`, and all `gt cell`
commands to post-migration.

---

## Finding 6: Cross-Program Composition Before Base Model Works (design-integration.md)

**Severity: HIGH — designing features that require parser and schema changes**

Design-integration.md Section 3 proposes three cross-program composition
patterns:

- **Pattern A:** Sequential pour with template injection (completion-watcher
  generates .cell files) — requires a completion-watcher that doesn't exist.
- **Pattern B:** Shared yields via SQL hard cells — tight coupling between
  programs via internal cell/field names.
- **Pattern C:** Cross-program `given` syntax (`given fact-check/verify.claims`)
  — requires parser changes and a new `givens.source_program` column.

The document recommends Pattern A for v0, Pattern B for v1, Pattern C for v2.
But even Pattern A requires building a completion-watcher, trigger registration
system, and template substitution engine — none of which exist.

The base system currently handles single programs with single pistons. Designing
multi-program coordination before single-program correctness is established
(13 conformance bugs still open) puts the cart before the horse.

**Recommendation:** Defer all cross-program composition to a separate design
bead after the frame migration lands. The current `ct eval` mechanism (submit
to cell-zero-eval) is sufficient for program chaining in the near term.

---

## Finding 7: Duplicate Metadata Table Designs

**Severity: LOW — easily reconciled, but shows lack of coordination**

Three documents design metadata tables independently:

| Document | Table | Columns |
|----------|-------|---------|
| design-data.md | `retort_meta` | `key_name VARCHAR(64), value_text VARCHAR(4096), updated_at` |
| design-security.md | `schema_metadata` | `key_name VARCHAR(64), value VARCHAR(256), updated_at` |
| design-api.md | `retort_meta` | `key_name VARCHAR(64), value_int INT, value_text VARCHAR(256)` |

These should be one table. design-data.md's version is the most complete
(includes the `retort_migrations` companion table). design-api.md adds
`value_int` for the epoch. design-security.md uses a different table name
entirely.

**Recommendation:** Adopt design-data.md's `retort_meta` with an added
`value_int` column (from design-api.md). Drop `schema_metadata` from
design-security.md. Ensure all three documents reference the same table.

---

## Finding 8: Piston Prompt v2 is Premature (design-api.md Section 3)

**Severity: LOW — correct direction, wrong timing**

The piston prompt v2 (ct-only, ~80 lines, no raw SQL) is the right end state.
But writing it now, before the frame migration changes the stored procedure
signatures, means it will need revision again when the procedures change.

The prompt v2 references `ct version` (not yet implemented), schema_epoch
(table not yet created), and auto-respawn behavior (not yet in `ct submit`).
Shipping a prompt that references non-existent features risks piston failures
during the transition.

**Recommendation:** Write the prompt v2 after the frame migration lands and
all referenced `ct` commands work. The current prompt (v1) works for the
transition period. The security design's R2.4 (defense-in-depth for transition)
covers the gap.

---

## Summary: What Stays, What Goes

### In Scope (next phase)

| Item | Source | Rationale |
|------|--------|-----------|
| Frame-based claim lifecycle | design-data.md | Core mission |
| retort_meta + retort_migrations tables | design-data.md | Schema versioning needed for migration |
| cell_create_frame procedure | design-data.md | Core operation |
| Backfill strategy (lazy + ct migrate) | design-data.md | Migration prerequisite |
| ct version command | design-api.md | Schema epoch verification |
| Modified ct submit (append-only, atomic bindings) | design-api.md | Bug fixes |
| Modified ct pour (schema_epoch check) | design-api.md | Migration safety |
| piston_register with schema_epoch | design-api.md | Stale piston detection |
| S1.1: Eliminate claim-phase commit | design-scale.md | Low effort, high impact |
| S4.1: Scope resolveInputs to latest gen | design-scale.md | Fixes correctness bug |
| S4.2: Yield UNIQUE index migration | design-scale.md | Required by frame migration |
| R2.1: Migrate piston to ct-only (planning only) | design-security.md | Sets direction |
| R1.4: Parameterize SQL in stored procedures | design-security.md | Required for correctness |
| ct yield command | design-ux.md | No dependency, low risk, immediate value |
| ct help command | design-ux.md | No dependency, low risk |

### Defer (post-migration beads)

| Item | Source | Rationale |
|------|--------|-----------|
| Gas Town integration (all of design-integration.md except schema epoch) | design-integration.md | Premature — depends on stable frame model |
| Cross-program composition (Patterns A/B/C) | design-integration.md | Premature — single-program correctness first |
| `gt cell` command surface (7 commands) | design-integration.md | Premature — no base to build on |
| ct thaw + ct thaw --cascade | design-api.md, design-ux.md | Depends on frame migration; conflicting designs need reconciliation |
| ct convergence | design-ux.md | Depends on frame migration |
| Piston prompt v2 | design-api.md | Write after migration lands |
| In-memory ReadySet (S2.1) | design-scale.md | Significant new subsystem |
| Frame compaction (S4.3) | design-scale.md | Migration hasn't landed |
| claim_log rotation (S4.4) | design-scale.md | No production workloads |
| Metrics instrumentation | design-scale.md | Stabilize first, measure second |
| Security P2+ (R1.2, R2.2, R3.1, R4.3-R4.5) | design-security.md | Hardening after correctness |
| Error messages with frame IDs | design-ux.md | Depends on frame migration |
| ct watch iteration tree | design-ux.md | Depends on frame migration |
| Piston prompt narration updates | design-ux.md | After commands stabilize |

### Must Reconcile Before Proceeding

1. **ct thaw semantics:** design-api.md (destructive) vs design-ux.md (append-only).
   Adopt design-ux.md's approach.
2. **Metadata table:** Unify `retort_meta` (design-data.md) with `schema_metadata`
   (design-security.md) and the variant in design-api.md.
3. **cell_create_frame:** design-data.md allows any cell type with generation
   parameter; design-api.md restricts to stem cells only. The formal model
   supports both (createFrame has no cell-type restriction). Adopt design-data.md's
   more general version.

---

## Scope-Creep Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Gas Town integration blocks migration | Medium | High | Defer integration; it's not on the critical path |
| Conflicting ct thaw designs cause rework | High | Medium | Reconcile now, implement later |
| 17 security recommendations fragment focus | Medium | Medium | Limit to P0 items for next phase |
| New commands regress existing CLI | Low | High | Add only ct version + ct yield/help (no migration deps) |
| Metadata table inconsistency causes schema bugs | High | Low | Unify to one table before any implementation |
| Piston prompt v2 references unimplemented features | Medium | Medium | Write after migration, not before |

---

## Conclusion

The six design documents collectively describe work that would take 3-4 phases
to implement. The next phase should be tightly scoped to:

1. **Complete the frame migration** (design-data.md core: re-key yields, drop
   cells.state, cell_create_frame, backfill).
2. **Add schema versioning** (retort_meta table, ct version, piston_register
   epoch check).
3. **Fix conformance bugs** enabled by the frame migration (the 13 Group A/B
   bugs from do-7i1).
4. **Quick wins** with no migration dependency (ct yield, ct help, S1.1
   commit reduction, S4.1 resolveInputs fix).

Everything else — Gas Town integration, cross-program composition, ct thaw,
security hardening, in-memory caching, piston prompt v2, observability metrics
— should be filed as separate beads for future phases.
