# Eval Loop Rewrite: Effect-Aware Execution Engine

**Date**: 2026-03-19
**Bead**: do-dfh9.1 (draft)
**Status**: Draft — pending Seven Sages review

---

## 1. Goal

Replace `replEvalStep` (818 lines) and restructure `replSubmit` (987 lines) with an effect-aware execution engine where:

- **Pure** cells execute inline without piston involvement
- **Replayable** cells dispatch to pistons with auto-retry (validate before write)
- **NonReplayable** cells dispatch with transaction or branch isolation

The new engine must:
- Pass all existing tests (`e2e_test.go`, `concurrency_test.go`)
- Fix the oracle ordering bug (validate before write)
- Classify cells by effect level at claim time
- Support configurable retry budgets per cell
- Be proved correct in Lean (`formal/EffectEval.lean`)

## 2. What Gets Deleted (~400 lines)

| Function | Lines | Why |
|----------|-------|-----|
| `cmdRun` | 18-111 | Legacy stored-proc path. Superseded by Go-native. |
| `cmdRepl` | 607-803 | Deprecated REPL. Dead code in current main.go. |
| `submitYieldCall` | 262-275 | Stored-proc wrapper. Only caller was cmdRun. |
| `submitYieldDirect` | 278-293 | Dead code. No callers. |
| `replBar`, `replStepSep`, `replAnnot`, `replReadValue` | 1542-1598 | REPL display helpers. Dead once cmdRepl deleted. |
| `replDocState` | 1604-1748 | REPL document renderer. Dead once cmdRepl deleted. |
| `replCellCounts` | 1524-1539 | Only called from cmdRepl. |

## 3. What Gets Preserved (moved to new structure)

| Function | Why |
|----------|-----|
| `resolveInputs` | Needed by all entry points. Unchanged. |
| `interpolateBody` | String replacement. Unchanged. |
| `getYieldFields` | Yield field lookup. Unchanged. |
| `replGetOracles` | Oracle display for piston output. Unchanged. |
| `recordBindings` | Formal invariants I10/I11. Unchanged. |
| `hasBottomedDependency` | Bottom propagation. Unchanged. |
| `bottomCell` | Bottom marking. Unchanged. |
| `checkGuardSkip` | Guard oracle flow. Unchanged. |
| `replRespawnStem` | Stem lifecycle. Unchanged. |
| `isIterationCell` | Utility. Unchanged. |
| `cmdThaw` / `thawCell` | Independent utility. Unchanged. |
| `emitCompletionBead` | GT integration. Unchanged. |
| `replRelease` / `replReleaseAll` | Claim cleanup. Unchanged. |

## 4. New Architecture

### 4.1 New types

```go
// EffLevel classifies cells by recoverability.
// Corresponds to EffLevel in formal/EffectEval.lean.
type EffLevel int

const (
    EffPure          EffLevel = 0 // deterministic, inline execution
    EffReplayable    EffLevel = 1 // non-deterministic value, auto-retryable
    EffNonReplayable EffLevel = 2 // mutates space/world, cascade-thaw on failure
)

// EvalAction is what the eval step decides to do.
// Corresponds to EvalAction in formal/EffectEval.lean.
type EvalAction int

const (
    ActionComplete       EvalAction = iota // all non-stem cells frozen/bottomed
    ActionQuiescent                        // no ready cells (polling returns)
    ActionExecPure                         // execute inline, no piston
    ActionDispatchReplay                   // dispatch to piston, auto-retry
    ActionDispatchNonReplay                // dispatch with isolation
)

// EvalResult is the output of one eval step.
type EvalResult struct {
    Action    EvalAction
    ProgID    string
    CellID    string
    CellName  string
    Body      string
    BodyType  string
    EffLevel  EffLevel
    FrameID   string
    RetryMax  int    // from cell annotation or default (3)
}

// SubmitResult is the outcome of validating + freezing a yield.
type SubmitResult int

const (
    SubmitOK         SubmitResult = iota // yield frozen
    SubmitOracleFail                     // deterministic oracle rejected
    SubmitPartial                        // more yields needed
    SubmitError                          // infrastructure error
)
```

### 4.2 Effect inference

```go
// inferEffect determines a cell's effect level from its body and annotations.
// Called at pour time (parse.go) and verified at claim time.
//
// Corresponds to classifyEffect in formal/EffectEval.lean.
func inferEffect(bodyType, body string, annotations []string) EffLevel {
    // Explicit annotation overrides inference
    for _, a := range annotations {
        switch a {
        case "pure":          return EffPure
        case "replayable":    return EffReplayable
        case "nonreplayable": return EffNonReplayable
        }
    }

    // Infer from body
    switch bodyType {
    case "hard":
        if strings.HasPrefix(body, "literal:") {
            return EffPure
        }
        if strings.HasPrefix(body, "sql:") {
            if hasVolatileSQL(body) {
                return EffReplayable
            }
            return EffPure
        }
        if strings.HasPrefix(body, "dml:") {
            return EffNonReplayable
        }
        return EffPure // hard cell with pre-frozen yields

    case "soft":
        return EffReplayable

    case "stem":
        if containsDML(body) {
            return EffNonReplayable
        }
        return EffReplayable // stems default to replayable
    }

    return EffReplayable // safe default
}

// hasVolatileSQL checks for non-deterministic SQL functions.
func hasVolatileSQL(body string) bool {
    upper := strings.ToUpper(body)
    volatiles := []string{"NOW()", "RAND()", "UUID()", "CURRENT_USER()",
                          "CURRENT_TIMESTAMP", "SYSDATE()", "RANDOM()"}
    for _, v := range volatiles {
        if strings.Contains(upper, v) {
            return true
        }
    }
    return false
}
```

### 4.3 The new eval step

```go
// effectEvalStep is the replacement for replEvalStep.
// It finds the next ready cell, classifies its effect, and returns
// the appropriate action. Pure cells are executed inline.
//
// Corresponds to effectEvalStep in formal/EffectEval.lean.
// Theorem: effectEvalStep_preserves_wellFormed
// Theorem: effectEvalStep_decreases_nonFrozen (progressive trace)
func effectEvalStep(db *sql.DB, progID, pistonID, modelHint string) EvalResult {
    // 1. Reap stale claims (2-minute TTL)
    reapStaleClaims(db)

    // 2. Check completion (non-stem cells all frozen/bottomed)
    if progID != "" && programComplete(db, progID) {
        return EvalResult{Action: ActionComplete, ProgID: progID}
    }

    // 3. Find and claim a ready cell
    rc, frameID, err := findAndClaim(db, progID, pistonID, modelHint)
    if err != nil {
        return EvalResult{Action: ActionQuiescent, ProgID: progID}
    }

    // 4. Check for poisoned inputs (bottom propagation)
    if hasBottomedDependency(db, rc.progID, rc.cellID) {
        bottomCell(db, rc.progID, rc.cellName, rc.cellID, "bottom: dependency error")
        doltCommit(db, "cell: bottom propagation "+rc.cellName)
        return EvalResult{
            Action: ActionExecPure, ProgID: rc.progID,
            CellID: rc.cellID, CellName: rc.cellName,
        }
    }

    // 5. Classify effect level
    eff := inferEffect(rc.bodyType, rc.body, rc.annotations)
    retryMax := rc.retryMax // from cell annotation, default 3

    // 6. Dispatch by effect level
    switch eff {
    case EffPure:
        result := execPure(db, rc, frameID, pistonID)
        return result

    case EffReplayable:
        // Mark computing, return dispatch action
        markComputing(db, rc.cellID, pistonID)
        logClaim(db, frameID, pistonID)
        doltCommit(db, "cell: dispatch replayable "+rc.cellName)
        return EvalResult{
            Action: ActionDispatchReplay, ProgID: rc.progID,
            CellID: rc.cellID, CellName: rc.cellName,
            Body: rc.body, BodyType: rc.bodyType,
            EffLevel: EffReplayable, FrameID: frameID,
            RetryMax: retryMax,
        }

    case EffNonReplayable:
        markComputing(db, rc.cellID, pistonID)
        logClaim(db, frameID, pistonID)
        doltCommit(db, "cell: dispatch nonreplayable "+rc.cellName)
        return EvalResult{
            Action: ActionDispatchNonReplay, ProgID: rc.progID,
            CellID: rc.cellID, CellName: rc.cellName,
            Body: rc.body, BodyType: rc.bodyType,
            EffLevel: EffNonReplayable, FrameID: frameID,
            RetryMax: retryMax,
        }
    }

    return EvalResult{Action: ActionQuiescent, ProgID: progID}
}
```

### 4.4 Pure execution (inline)

```go
// execPure handles Pure cells inline: literals and safe SQL queries.
// No piston involvement. Validates and freezes in one step.
//
// Theorem: execPure_preserves_wellFormed
// Theorem: execPure_deterministic (same inputs → same outputs)
func execPure(db *sql.DB, rc *readyCellResult, frameID, pistonID string) EvalResult {
    markComputing(db, rc.cellID, pistonID)

    var value string
    switch {
    case strings.HasPrefix(rc.body, "literal:"):
        value = strings.TrimPrefix(rc.body, "literal:")

    case strings.HasPrefix(rc.body, "sql:"):
        query := strings.TrimSpace(strings.TrimPrefix(rc.body, "sql:"))
        if err := db.QueryRow(query).Scan(&value); err != nil {
            // SQL failure: count attempts, bottom after 3
            handleSQLFailure(db, rc, pistonID, err)
            return EvalResult{
                Action: ActionExecPure, ProgID: rc.progID,
                CellID: rc.cellID, CellName: rc.cellName,
            }
        }

    default:
        // Hard cell with pre-frozen yields (multi-yield literal)
        value = "_"
    }

    // Validate THEN write (oracle ordering fix)
    yields := getYieldFields(db, rc.progID, rc.cellName)
    for _, y := range yields {
        status := validateAndFreeze(db, rc.progID, rc.cellName, rc.cellID, y, value, frameID)
        if status == SubmitOracleFail {
            // Pure cells with oracle failures bottom (can't retry deterministic)
            bottomCell(db, rc.progID, rc.cellName, rc.cellID,
                fmt.Sprintf("pure cell oracle failure on %s", y))
            break
        }
    }

    releaseClaim(db, rc.cellID, pistonID)
    doltCommit(db, "cell: freeze pure "+rc.cellName)

    return EvalResult{
        Action: ActionExecPure, ProgID: rc.progID,
        CellID: rc.cellID, CellName: rc.cellName,
        Body: rc.body, BodyType: rc.bodyType,
    }
}
```

### 4.5 Validate-then-write (the oracle ordering fix)

```go
// validateAndFreeze checks oracles BEFORE writing yields.
// This is the critical fix: the current code writes then checks.
//
// Theorem: validateAndFreeze_appendOnly
//   (no DELETE+re-INSERT; either the yield is written once or not at all)
// Theorem: validateAndFreeze_oracleSound
//   (frozen yields always satisfy their deterministic oracles)
func validateAndFreeze(db *sql.DB, progID, cellName, cellID, fieldName, value, frameID string) SubmitResult {
    // Step 1: Check deterministic oracles BEFORE writing anything
    if !checkPureOracles(db, cellID, fieldName, value) {
        // Log failure to trace, do NOT write the yield
        db.Exec("INSERT INTO trace (id, cell_id, event_type, detail, created_at) "+
            "VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'oracle_fail', ?, NOW())",
            cellID, fmt.Sprintf("oracle check failed for %s.%s", cellName, fieldName))
        return SubmitOracleFail
    }

    // Step 2: Oracle passed — write and freeze the yield (single atomic write)
    res, err := db.Exec(
        "UPDATE yields SET value_text = ?, is_frozen = TRUE, frozen_at = NOW(), "+
            "frame_id = COALESCE(frame_id, ?) WHERE cell_id = ? AND field_name = ? AND is_frozen = FALSE",
        value, frameID, cellID, fieldName)
    if err != nil {
        return SubmitError
    }
    n, _ := res.RowsAffected()
    if n == 0 {
        // Yield already frozen (idempotent) or doesn't exist
        return SubmitError
    }

    // Step 3: Check if all yields for this cell are now frozen
    var remaining int
    db.QueryRow("SELECT COUNT(*) FROM yields WHERE cell_id = ? AND is_frozen = FALSE", cellID).Scan(&remaining)
    if remaining > 0 {
        return SubmitPartial
    }

    // Step 4: All yields frozen — complete the freeze
    completeCellFreeze(db, progID, cellName, cellID)
    return SubmitOK
}

// checkPureOracles runs deterministic oracle checks against a value
// WITHOUT writing anything to the database.
func checkPureOracles(db *sql.DB, cellID, fieldName, value string) bool {
    var detCount int
    db.QueryRow("SELECT COUNT(*) FROM oracles WHERE cell_id = ? AND oracle_type = 'deterministic'",
        cellID).Scan(&detCount)
    if detCount == 0 {
        return true // no oracles to check
    }

    rows, err := db.Query("SELECT condition_expr FROM oracles WHERE cell_id = ? AND oracle_type = 'deterministic'", cellID)
    if err != nil {
        return true // fail open on query error
    }
    defer rows.Close()

    passed := 0
    total := 0
    for rows.Next() {
        var cond string
        rows.Scan(&cond)
        if strings.HasPrefix(cond, "guard:") {
            passed++
            total++
            continue // guards are flow control, auto-pass
        }
        total++
        switch {
        case cond == "not_empty":
            if value != "" { passed++ }
        case cond == "is_json_array":
            if strings.HasPrefix(value, "[") && strings.HasSuffix(strings.TrimSpace(value), "]") { passed++ }
        default:
            passed++ // unknown oracle type: pass (fail-open)
        }
    }
    return passed >= total
}
```

### 4.6 Replayable submission with auto-retry

```go
// submitReplayable is called when a piston submits a value for a Replayable cell.
// It validates before writing and supports auto-retry.
//
// Theorem: replayable_retry_preserves_state
//   (if oracle fails, the tuple space is unchanged — safe to retry)
func submitReplayable(db *sql.DB, progID, cellName, fieldName, value string, retryBudget *int) (string, string) {
    cellID := lookupComputingCell(db, progID, cellName)
    if cellID == "" {
        return "error", "cell not found or not computing"
    }
    frameID := latestFrameID(db, progID, cellName)

    // Validate BEFORE writing (the critical invariant)
    status := validateAndFreeze(db, progID, cellName, cellID, fieldName, value, frameID)

    switch status {
    case SubmitOK:
        return "frozen", fmt.Sprintf("%s.%s frozen", cellName, fieldName)
    case SubmitPartial:
        return "partial", fmt.Sprintf("%s.%s frozen, more yields needed", cellName, fieldName)
    case SubmitOracleFail:
        *retryBudget--
        if *retryBudget <= 0 {
            bottomCell(db, progID, cellName, cellID, "exhausted retry budget")
            doltCommit(db, fmt.Sprintf("cell: bottom %s after retry exhaustion", cellName))
            return "bottom", "retry budget exhausted"
        }
        return "oracle_fail", fmt.Sprintf("oracle check failed (%d retries remaining)", *retryBudget)
    default:
        return "error", "submit failed"
    }
}
```

### 4.7 NonReplayable with transaction isolation

```go
// execNonReplayableTransaction executes a NonReplayable cell within
// a Dolt transaction. Used when all effects are Dolt-only (no ExtIO).
//
// Cost: ~1ms (vs ~500ms for branch isolation)
func execNonReplayableTransaction(db *sql.DB, rc *readyCellResult, frameID, pistonID string) EvalResult {
    // BEGIN explicit transaction
    tx, err := db.Begin()
    if err != nil {
        replRelease(db, rc.cellID, pistonID, "tx_fail")
        return EvalResult{Action: ActionQuiescent}
    }

    // Execute the DML
    query := strings.TrimSpace(strings.TrimPrefix(rc.body, "dml:"))
    var result string
    if err := tx.QueryRow(query).Scan(&result); err != nil {
        tx.Rollback()
        handleNonReplayableFailure(db, rc, pistonID, err)
        return EvalResult{Action: ActionExecPure, ProgID: rc.progID,
            CellID: rc.cellID, CellName: rc.cellName}
    }

    // Validate and freeze within the transaction
    yields := getYieldFields(db, rc.progID, rc.cellName)
    for _, y := range yields {
        if !checkPureOracles(db, rc.cellID, y, result) {
            tx.Rollback()
            handleNonReplayableFailure(db, rc, pistonID, fmt.Errorf("oracle fail"))
            return EvalResult{Action: ActionExecPure, ProgID: rc.progID,
                CellID: rc.cellID, CellName: rc.cellName}
        }
    }

    // Commit the transaction
    if err := tx.Commit(); err != nil {
        handleNonReplayableFailure(db, rc, pistonID, err)
        return EvalResult{Action: ActionQuiescent}
    }

    // Freeze yields (outside transaction, on committed data)
    for _, y := range yields {
        validateAndFreeze(db, rc.progID, rc.cellName, rc.cellID, y, result, frameID)
    }
    releaseClaim(db, rc.cellID, pistonID)
    doltCommit(db, "cell: freeze nonreplayable "+rc.cellName)

    return EvalResult{
        Action: ActionExecPure, ProgID: rc.progID,
        CellID: rc.cellID, CellName: rc.cellName,
    }
}
```

### 4.8 Entry point changes

```go
// cmdPiston becomes effect-aware:
func cmdPiston(db *sql.DB, progID string) {
    pistonID := genPistonID()
    retryBudgets := map[string]int{} // cellID → remaining retries

    for {
        es := effectEvalStep(db, progID, pistonID, "")

        switch es.Action {
        case ActionComplete:
            emitCompletionBead(db, progID)
            return
        case ActionQuiescent:
            return
        case ActionExecPure:
            // Already handled inline by effectEvalStep/execPure
            continue
        case ActionDispatchReplay:
            // Print dispatch info for piston, track retry budget
            retryBudgets[es.CellID] = es.RetryMax
            printDispatch(es)
            return // piston takes over, will call ct submit
        case ActionDispatchNonReplay:
            printDispatch(es)
            return
        }
    }
}
```

## 5. Formal Correspondence

Every new function has a corresponding definition or theorem in `formal/EffectEval.lean`:

| Go function | Lean definition | Key theorem |
|-------------|----------------|-------------|
| `EffLevel` | `EffLevel` inductive | `join_comm`, `join_assoc`, `join_idem` |
| `inferEffect` | `classifyEffect` | `classifyEffect_sound` |
| `effectEvalStep` | `effectEvalStep` | `effectEvalStep_preserves_wellFormed` |
| `execPure` | `execPure` | `execPure_deterministic` |
| `validateAndFreeze` | `validateThenFreeze` | `validateThenFreeze_appendOnly` |
| `submitReplayable` | `replayableSubmit` | `replayable_retry_preserves_state` |
| `effectEvalStep` loop | `ProgressiveTrace` | `effectEval_decreases_nonFrozen` |

## 6. Migration Strategy

### Phase 1: Introduce new types, keep old code (1 day)
- Add `EffLevel`, `EvalAction`, `EvalResult` types
- Add `inferEffect` and `hasVolatileSQL`
- Add `effect` column to cells table (VARCHAR(16), nullable, default NULL)
- Old code continues to work — new types are unused

### Phase 2: Write new eval step alongside old (2 days)
- Write `effectEvalStep` as a NEW function (don't touch `replEvalStep`)
- Write `validateAndFreeze` and `checkPureOracles`
- Wire `effectEvalStep` to a new command: `ct piston2` (temporary)
- Run tests against both old and new

### Phase 3: Write new submit path (1 day)
- Write `submitReplayable` using `validateAndFreeze`
- Wire to `ct submit2` (temporary)
- Test oracle ordering fix

### Phase 4: Cut over (1 day)
- Replace `cmdPiston` to use `effectEvalStep`
- Replace `cmdNext` to use `effectEvalStep`
- Replace `cmdSubmit` to use `submitReplayable`
- Delete `cmdRun`, `cmdRepl`, dead code (~400 lines)
- Update tests

### Phase 5: Add auto-retry (1 day)
- Implement retry loop in `cmdPiston` for Replayable cells
- Add `retries=N` annotation parsing in `parse.go`
- Test auto-retry with oracle failures

### Phase 6: Add transaction isolation (1 day)
- Implement `execNonReplayableTransaction`
- Wire for `dml:` body prefix cells
- Test with rollback scenarios

Total: ~7 days, incrementally shippable at each phase.

## 7. Test Plan

| Test | What it verifies |
|------|-----------------|
| Existing `TestE2E_HardCellProgram` | Pure cells still work |
| Existing `TestConcurrency_*` | Claim mutex still holds |
| New `TestEffectInference` | Effect classification from body/annotations |
| New `TestValidateBeforeWrite` | Oracle rejects don't write yields |
| New `TestReplayableRetry` | Auto-retry works, budget decrements, bottom on exhaustion |
| New `TestNonReplayableTransaction` | DML in transaction, rollback on failure |
| New `TestPureSQL_VolatileDetection` | NOW()/RAND() elevates to Replayable |
