# Migration Proposal: ericfode/cell → ericfode/dolt-cell

## Summary

This document proposes what to migrate from [ericfode/cell](https://github.com/ericfode/cell)
to ericfode/dolt-cell, based on a full survey of the source repository.

**Guiding rules (from the bead):**
- **KEEP**: Turnstyle syntax (the language/DSL), Dolt implementation, Research and experiments
- **DO NOT MIGRATE**: Any Python code, The old Go implementation

---

## Source Repository Overview

Cell is "a context-free DSL for reactive computation graphs" — a dual-substrate
fusion language where programs are documents, execution fills in values, and cells
progressively crystallize from soft (LLM-evaluated) to hard (deterministic) under
oracle pressure.

| Area | Language | Lines | Files |
|------|----------|-------|-------|
| Go (cmd + internal) | Go | ~18K | ~57 |
| Lean4 (BeadCalculus) | Lean 4 | ~4,700 | 13 |
| Python (tools) | Python | ~3,600 | ~20 |
| Docs (design, research, plans, reviews) | Markdown | ~19K | ~45 |
| Cell examples (docs/examples) | Cell DSL | ~5K | 55 |
| Cell frames (docs/frames) | Cell DSL | ~1K | 17 |
| Evolution rounds (round-1 through round-17) | Cell DSL + MD | ~15K | ~220 |
| Traces | Cell DSL | ~1K | 13 |

---

## MIGRATE: Turnstyle Syntax (Language/DSL)

### 1. Language Specifications

| File | Lines | Rationale |
|------|-------|-----------|
| `docs/design/cell-v0.2-spec.md` | 819 | **Current spec.** Defines all turnstyle operators (⊢, ∴, ⊢=, ⊨, §, «», ≡, →, ⊥, ⊢∘), cell types, molecule syntax, execution model. The canonical reference. |
| `docs/design/cell-v0.1-spec.md` | 346 | **Prior spec.** Historical context for evolution decisions. |
| `docs/design/cell-minimum-viable-spec.md` | 425 | **Kernel spec.** Distills the 12 essential features. Critical for knowing what's core vs. sugar. |
| `docs/design/cell-computational-model.md` | 665 | **Theoretical foundation.** Dual-substrate fusion model, document-is-state principle, crystallization semantics. |

### 2. Example Cell Programs

| Directory | Files | Rationale |
|-----------|-------|-----------|
| `docs/examples/` | 55 .cell files | Real-world Cell programs demonstrating every feature: survey, code-review, security-audit, towers-of-hanoi, cell-zero (metacircular evaluator), Gas Town ops (polecat-work, refinery-patrol, etc.). Essential test corpus and documentation-by-example. |
| `docs/frames/` | 17 .cell files | Frame sequences showing cell crystallization over eval steps (haiku-oracle, sort-proof, quadratic). Demonstrate the execution model concretely. |
| `docs/design/cell-zero.cell` | 594 | **The metacircular evaluator.** Cell that evaluates Cell. Core to the self-bootstrapping thesis. |
| `docs/design/cell-zero-sketch.cell` | 209 | Kernel sketch of the metacircular evaluator. |
| `docs/design/frame-bead-format.cell` | ~50 | Frame format definition. |

### 3. Execution Traces

| Directory | Files | Rationale |
|-----------|-------|-----------|
| `traces/` | 13 .cell files | Executable test programs (accumulator, fibonacci-crystal, diamond-deps, fizzbuzz, etc.). Serve as smoke tests for any new parser/runtime. |

---

## MIGRATE: Dolt Implementation

The Dolt-specific implementation is primarily the **Retort** database schema and
the design documents describing the beads substrate mapping.

### 4. Retort Database Schema

| File | Lines | Rationale |
|------|-------|-----------|
| `internal/cell/retort/schema.go` | ~140 | **The DDL.** Defines the Dolt database schema: programs, cells, givens, yields, oracles, oracle_checks, executions, events tables. This is the data model. Extract as SQL DDL (not Go code). |

**Proposed action**: Extract the DDL strings from `schema.go` into a standalone
`schema.sql` file. The Go wrapper is excluded per the "no Go" rule, but the SQL
schema itself defines the Dolt implementation.

### 5. Beads Substrate Design

| File | Lines | Rationale |
|------|-------|-----------|
| `docs/plans/2026-03-12-beads-substrate-design.md` | ~130 | Maps Cell concepts to beads (the `bd` system). Cells → beads, dependencies → blocking, soft body → description, frozen → closed. |
| `docs/design/cell-sql-library-sketch.md` | 407 | SQL compilation strategy for Cell programs. How turnstyle syntax compiles to INSERT statements targeting Dolt. |
| `docs/design/formula-resolution.md` | 249 | Formula dependency resolution — how Cell DAGs resolve in the Gas Town formula engine. |
| `docs/design/gas-city-formula-engine-vision.md` | 352 | Vision doc for the formula engine that runs on Dolt. |

### 6. SQL Emission Logic (as reference)

| File | Lines | Rationale |
|------|-------|-----------|
| `internal/cell/retort/emit_sql.go` | ~100 | Compiles Cell programs to SQL INSERT statements. While Go code is excluded, the *logic* of how cells map to SQL rows is the Dolt implementation. Extract as a reference doc or port to a non-Go language. |

---

## MIGRATE: Research and Experiments

### 7. Design Documents

| Directory | Files | Lines | Rationale |
|-----------|-------|-------|-----------|
| `docs/design/` (remaining) | 10 | ~4,300 | Gas City analysis (visualization, synthesis, Wolfram paradigm, information theory, power-user argument), intermediate language survey, mockups. Foundational research. |
| `docs/research/gas-city/` | 9 + diagrams | ~6,200 | Six research tracks (orchestration, reactive dataflow, agent memory, tool ecosystems, production deployments, emergent computation) plus three synthesis docs (gap analysis, abstraction map, architecture sketch). |
| `docs/plans/` | 6 | ~2,000 | Roadmaps: bootstrap roadmap, syntax discovery design, syntax candidates, formula survey, language spec plan. |
| `docs/reviews/` | 4 | ~1,500 | Peer reviews: R11 eval, v0.1 spec review, cleanup recommendations, codebase survey. |

### 8. Evolution Rounds

| Directory | Rounds | Files | Rationale |
|-----------|--------|-------|-----------|
| `evolution/round-1` through `round-17` | 17 | ~220 | Systematic iterative testing. Each round contains variants (.cell files) and synthesis (.md files). Documents the empirical evidence behind every language decision. |
| `evolution/synthesis-r9-r11.md` | 1 | 200 | Cross-round synthesis scoring 17 features (tier 1/2/3 readiness), 7 design principles, 3 discovered bugs. |

### 9. Lean4 Formal Proofs

| Directory | Files | Lines | Rationale |
|-----------|-------|-------|-----------|
| `lean4/` (full directory) | 13 + config | 4,735 | **Formal verification of the language semantics.** Zero `sorry`s, zero custom axioms. Covers: effect system (Quality, Cost, Freshness, Provenance), confluence proof (all eval orders → same result), program algebra (composition laws), DAG operations, cell state model. This IS the formal spec of Turnstyle. |

Key modules:
- `GasCity.lean` (2,211 lines) — Effect system formalization
- `Confluence.lean` (451 lines) — Eval-order independence proof
- `ProgramAlgebra.lean` (745 lines) — Algebraic composition laws
- `GraphOps.lean` (719 lines) — DAG reachability, topological sort
- `Formula.lean` (116 lines) — Cell/Wire/Formula structures
- `Spreadsheet.lean` (127 lines) — Cell state model
- Plus: `lakefile.toml`, `lean-toolchain`, `Main.lean`, `BeadCalculus.lean` (project config)

---

## DO NOT MIGRATE

### Go Code (cmd/ + internal/)

| Directory | Lines | Why excluded |
|-----------|-------|--------------|
| `cmd/cell/` | 313 | CLI parser — will be rewritten |
| `cmd/rt/` | 507 | Retort CLI — will be rewritten |
| `cmd/dashboard/` | 477 | Web dashboard — will be rewritten |
| `internal/cell/` (base) | 1,700 | Basic AST/parser/lexer — will be rewritten |
| `internal/cell/parser/` | 7,000 | Extended parser (molecules) — will be rewritten |
| `internal/cell/retort/` | 5,200 | Retort engine (except schema DDL) — will be rewritten |
| `internal/cell/subzero/` | 3,000 | LLM integration — will be rewritten |

**Exception**: `retort/schema.go` DDL strings should be extracted as SQL (see item 4).
The Go code wrapping the DDL is not migrated, but the SQL schema is the Dolt implementation.

### Python Code (tools/)

| Directory | Lines | Why excluded |
|-----------|-------|--------------|
| `tools/cell-validator/` | 740 | ML-based syntax validator — Python |
| `tools/cell-zero/` | 2,600 | Bootstrap evaluator — Python |
| `tools/eval-one/` | 907 | Eval-one implementation — Python |

### Miscellaneous

| File | Why excluded |
|------|--------------|
| `go.mod`, `go.sum` | Go module files — not needed |
| `AGENTS.md` | Beads workflow specific to the old repo |
| `.gitignore` | Start fresh for dolt-cell |

---

## Proposed Directory Structure in dolt-cell

```
dolt-cell/
├── spec/
│   ├── cell-v0.2-spec.md          ← Current language spec
│   ├── cell-v0.1-spec.md          ← Prior spec (historical)
│   ├── cell-minimum-viable-spec.md ← Kernel spec
│   └── cell-computational-model.md ← Theoretical foundation
├── schema/
│   └── retort.sql                 ← DDL extracted from schema.go
├── lean4/                         ← Full Lean4 directory (as-is)
│   ├── BeadCalculus/
│   │   ├── GasCity.lean
│   │   ├── Confluence.lean
│   │   ├── ProgramAlgebra.lean
│   │   ├── GraphOps.lean
│   │   ├── Formula.lean
│   │   ├── Spreadsheet.lean
│   │   ├── DAG.lean
│   │   ├── CellType.lean
│   │   ├── ProcessModel.lean
│   │   ├── Unified.lean
│   │   └── Basic.lean
│   ├── BeadCalculus.lean
│   ├── Main.lean
│   ├── lakefile.toml
│   └── lean-toolchain
├── examples/                      ← Merged from docs/examples + traces
│   ├── hello.cell
│   ├── survey.cell
│   ├── code-review.cell
│   ├── ... (55 example files)
│   └── traces/                    ← Executable test programs
│       ├── accumulator.trace.cell
│       ├── fibonacci-crystal.cell
│       └── ... (13 trace files)
├── frames/                        ← Frame sequences
│   ├── haiku-oracle-f0.cell
│   ├── sort-proof-f0.cell
│   └── ... (17 frame files)
├── docs/
│   ├── design/                    ← Design docs (minus specs, moved to spec/)
│   │   ├── cell-sql-library-sketch.md
│   │   ├── formula-resolution.md
│   │   ├── gas-city-*.md          ← Gas City research
│   │   ├── intermediate-language-survey.md
│   │   ├── cell-zero.cell         ← Metacircular evaluator
│   │   └── cell-zero-sketch.cell
│   ├── research/                  ← Full research directory (as-is)
│   │   └── gas-city/
│   ├── plans/                     ← Roadmaps and plans (as-is)
│   └── reviews/                   ← Peer reviews (as-is)
├── evolution/                     ← Full evolution directory (as-is)
│   ├── round-1/ through round-17/
│   └── synthesis-r9-r11.md
└── README.md
```

---

## Migration Summary

| Category | Files | Lines | Action |
|----------|-------|-------|--------|
| Language specs | 4 | ~2,255 | Copy to `spec/` |
| Cell examples | 55 | ~5,000 | Copy to `examples/` |
| Cell frames | 17 | ~1,000 | Copy to `frames/` |
| Execution traces | 13 | ~1,000 | Copy to `examples/traces/` |
| Metacircular evaluator | 3 | ~850 | Copy to `docs/design/` |
| Retort DDL | 1 | ~140 | Extract SQL to `schema/retort.sql` |
| Beads/SQL design docs | 4 | ~1,100 | Copy to `docs/design/` |
| Gas City design docs | 6 | ~2,500 | Copy to `docs/design/` |
| Research docs | 9+ | ~6,200 | Copy to `docs/research/` (as-is) |
| Plans | 6 | ~2,000 | Copy to `docs/plans/` |
| Reviews | 4 | ~1,500 | Copy to `docs/reviews/` |
| Lean4 proofs | 13+ | ~4,735 | Copy `lean4/` (as-is) |
| Evolution rounds | ~220 | ~15,000 | Copy `evolution/` (as-is) |
| **TOTAL MIGRATED** | **~355** | **~43,000** | |
| **NOT MIGRATED (Go)** | ~57 | ~18,000 | Excluded |
| **NOT MIGRATED (Python)** | ~20 | ~3,600 | Excluded |

---

## Open Questions

1. **Retort schema extraction**: Should `emit_sql.go` logic be documented as a
   reference alongside the DDL, or is the schema alone sufficient?

2. **Evolution round pruning**: Rounds 1-8 are exploratory. Should they be
   migrated in full, or only the synthesis document (`synthesis-r9-r11.md`)
   plus rounds 9-17?

3. **Lean4 lake dependencies**: The Lean4 project depends on Mathlib. The
   `lakefile.toml` and `lean-toolchain` should be migrated as-is, but verify
   compatibility with the target Lean toolchain version.

4. **AGENTS.md**: The old repo's AGENTS.md is repo-specific workflow config.
   dolt-cell will need its own. Should any content be adapted?
