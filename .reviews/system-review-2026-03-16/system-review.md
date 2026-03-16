# System Review: dolt-cell — 2026-03-16

## Executive Summary

dolt-cell is at an inflection point. The core runtime works end-to-end: pistons claim cells, evaluate them, submit yields, and oracles check results. The ct watch TUI has gone from ANSI-clear-screen hack to a polished live debugger in one day. The Phase B parser handles 90%+ of the turnstyle DSL without LLM. But the codebase is a 2600-line monolith with 50+ unchecked db.Exec calls, zero integration tests, and two critical design gaps (perpetual cells, crystallization) blocking the cell-zero vision.

**Overall health: B-** — working but fragile, well-designed but under-tested.

## Sprint 1: Do Now

### 1. Fix piston ID collision risk
- **Impact**: Two pistons spawned <100ms apart get identical IDs → infinite retry loop
- **Flagged by**: Runtime
- **Effort**: S (30 min)
- **Action**: Replace `time.Now().UnixNano()%100000000` with UUID or crypto/rand

### 2. Fix Ctrl-C leaking claimed cells
- **Impact**: ct next --wait exits without releasing cell claims → 10 min zombie
- **Flagged by**: Runtime
- **Effort**: S (1 hour)
- **Action**: Add defer cleanup in cmdNext signal handler

### 3. Complete the footer keybindings
- **Impact**: Users can't discover e/c/shift+tab/esc — 40% of bindings missing
- **Flagged by**: UX
- **Effort**: S (15 min)
- **Action**: Update footer text, add `?` help toggle

### 4. Add auto-retry on DB error in ct watch
- **Impact**: DB errors stick forever, user must quit and restart
- **Flagged by**: UX
- **Effort**: S (1 hour)
- **Action**: Keep ticking on error, show retry countdown, clear on recovery

### 5. Add yields section to detail pane
- **Impact**: Detail pane shows givens/oracles/trace but NOT current yield values
- **Flagged by**: UX
- **Effort**: S (30 min)
- **Action**: Query yields in queryDetailData, render in renderDetail

### 6. Add UNIQUE constraint on cells(program_id, name)
- **Impact**: Duplicate cell names in same program cause silent chaos
- **Flagged by**: Data
- **Effort**: S (15 min)
- **Action**: ALTER TABLE cells ADD UNIQUE INDEX

## Sprint 2: Do Next

### 7. Split main.go into watch.go + queries.go + repl.go
- **Impact**: 2600-line monolith is unmaintainable, untestable
- **Flagged by**: Architecture
- **Effort**: L (2-3 days)
- **Action**: Extract TUI (~800 lines), DB queries (~350 lines), deprecated REPL (~400 lines)

### 8. Wrap all 50+ unchecked db.Exec calls
- **Impact**: Silent data corruption, debugging impossible
- **Flagged by**: Architecture
- **Effort**: M (1 day)
- **Action**: Create execOrFatal wrapper, audit all Exec calls

### 9. Implement perpetual cells
- **Impact**: Blocks cell-zero evaluator. Highest strategic value.
- **Flagged by**: Roadmap
- **Effort**: M (2-3 days)
- **Action**: Add is_perpetual column, modify cell_submit to auto-reset

### 10. Add integration test harness
- **Impact**: 0% integration test coverage — can't verify pour→next→submit pipeline
- **Flagged by**: Testing
- **Effort**: M (3-4 days)
- **Action**: Ephemeral Dolt server, fresh schema per test, tear down cleanly

### 11. Model routing in ct next
- **Impact**: Haiku piston might get Opus cell — silent quality degradation
- **Flagged by**: Roadmap
- **Effort**: S (1 day)
- **Action**: Filter ready cells by model_hint, add --model flag to ct next

### 12. Standardize ready-cell detection
- **Impact**: 3 variants of same query, inconsistent workarounds
- **Flagged by**: Architecture, Data
- **Effort**: M (1 day)
- **Action**: Single helper function, all callers use it

## Backlog

### 13. Implement basic crystallization (memoization cache)
- **Flagged by**: Roadmap
- **Effort**: L
- **Action**: Cache soft cell results by input hash, cell_crystallize procedure

### 14. Add `dml:` hard cell type
- **Flagged by**: Roadmap
- **Effort**: M
- **Action**: Extend cell_eval_step to handle INSERT/UPDATE hard cells

### 15. Yield type validation
- **Flagged by**: Roadmap
- **Effort**: M
- **Action**: Add yield_type column, validate in cell_submit

### 16. Expand example corpus to 30+
- **Flagged by**: Testing, Roadmap
- **Effort**: M
- **Action**: Add stress tests (100+ cells, deep chains, parallel fans)

### 17. ct watch session recording
- **Flagged by**: UX, Roadmap
- **Effort**: M
- **Action**: Save execution trace to JSON for replay/post-mortem

### 18. Guard clause parsing
- **Flagged by**: Roadmap
- **Effort**: M
- **Action**: Extend parser for `guard: condition_expr`, check in ready_cells

### 19. SQL injection hardening
- **Flagged by**: Roadmap, Runtime
- **Effort**: M
- **Action**: Restrict hard cell SQL to SELECT, sanitize LLM output

### 20. Non-atomic yield→cell freeze race
- **Flagged by**: Runtime
- **Effort**: M
- **Action**: Wrap yield freeze + cell state update in single transaction

## What's Working Well

- **Dolt as runtime substrate** — observable, versionable, SQL-native. Right call.
- **Phase B parser** — fast, deterministic, handles 90%+ of spec. No LLM needed.
- **Piston loop** — simple, stateless, fault-tolerant. Any agent can be a piston.
- **ct watch TUI** — went from zero to polished debugger in one day. Real differentiator.
- **Semantic oracle judge cells** — elegant: oracles ARE cells, not special-cased.
- **Pour-as-cell** — parsing is a cell operation. Bootstrap is credible.
- **Example programs** — 14 working programs prove the DSL works (haiku, sort-proof, etc.)

## Health Scorecard

| Dimension | Grade | Notes |
|-----------|-------|-------|
| Architecture | C+ | 2600-line monolith, 50+ unchecked Execs, but clean domain model |
| UX | B+ | TUI is polished, missing help screen and error recovery |
| Runtime | B- | Core loop works, piston ID collision + signal leaks are fixable |
| Data | B | Schema is sound, ID generation and commit frequency need work |
| Testing | D+ | Parser 85% covered, everything else 0% |
| Roadmap | B+ | Clear vision, pragmatic trajectory, perpetual cells is the gate |
