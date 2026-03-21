# Pour-as-Cell: Piston-Driven Program Loading

**Date**: 2026-03-15
**Status**: Approved
**Prerequisite for**: Cell-zero bootstrap (evaluator-as-cell)

## One-Sentence Summary

`ct pour` creates a 2-cell pour-program in Retort, the running piston parses
the .cell text as a regular soft cell, and ct executes the resulting SQL —
making program loading a Cell operation instead of an external tool.

---

## How It Works

### The Pour-Program Template

Every `ct pour <name> <file.cell>` that doesn't have a pre-compiled .sql
creates a pour-program with two cells:

```
⊢ source                          (hard, literal)
  yield text ≡ <raw .cell file contents>
  yield name ≡ <program name>

⊢ parse                           (soft, depends on source)
  given source→text
  given source→name
  yield sql
  ∴ [pour-prompt rules — full Retort schema, turnstyle syntax,
     ID conventions, oracle classification, output format]
  ⊨ sql is not empty
  ⊨ sql contains valid SQL INSERT statements
```

The pour-program ID is content-addressed: `pour-{name}-{hash8}` where hash8
is the first 8 hex chars of SHA256(file contents). This means:

- **Same file** → same hash → same pour-program → already frozen → skip
- **Changed file** → different hash → new pour-program → fresh parse
- **Multiple versions** coexist in Retort (Dolt versioning tracks all)

### The ct pour Flow

```
ct pour myprogram file.cell
  │
  ├─ .sql file exists? → execute it directly (backward compatible)
  │
  └─ no .sql file:
      │
      ├─ Read file.cell, compute SHA256 → hash8
      ├─ pour-program ID = "pour-myprogram-{hash8}"
      │
      ├─ Check: is parse.sql yield already frozen?
      │   └─ YES → read value, execute SQL, done (cache hit)
      │
      └─ NO → create pour-program:
          ├─ INSERT source cell (hard, literal: file contents)
          ├─ INSERT source yields (text, name)
          ├─ INSERT parse cell (soft, pour-prompt as body)
          ├─ INSERT parse givens (source→text, source→name)
          ├─ INSERT parse yield (sql)
          ├─ INSERT parse oracles (not_empty)
          ├─ DOLT_COMMIT
          │
          ├─ Print "⏳ waiting for piston to parse..."
          ├─ Poll every 2s: SELECT value_text FROM yields
          │   WHERE cell_id = 'pour-myprogram-{hash8}-parse'
          │     AND field_name = 'sql' AND is_frozen = 1
          │
          ├─ Yield frozen → read SQL value
          ├─ Execute SQL (the parsed program's INSERTs)
          └─ Print "✓ myprogram: N cells"
```

### What the Piston Sees

The piston running `ct repl` (watch mode) sees the pour-program like any
other program. The `source` hard cell auto-freezes. Then `parse` becomes
ready — the piston reads the .cell text from the frozen `source→text` yield,
reads the pour-prompt instructions from the cell body, and produces SQL
INSERT statements. The oracle checks it's not empty. The yield freezes.

The piston doesn't know it's doing a pour. It's just evaluating a soft cell.

### The Pour-Prompt (Baked Into parse Cell Body)

The `∴` body of the `parse` cell contains the full pour-prompt rules from
`tools/pour-prompt.md`:

- Retort schema (cells, givens, yields, oracles)
- Turnstyle operator rules (⊢, given, yield, ∴, ⊨)
- ID conventions ({program}-{cellname}, g-{cell}-{field}, etc.)
- Cell type classification (hard/literal, soft, hard/computed)
- Oracle type classification (deterministic vs semantic)
- Output format (USE retort; INSERT...; CALL DOLT_COMMIT)

The program name and source text come from the `source` cell's frozen yields,
interpolated via the standard `«name»` and `«text»` reference mechanism.

---

## Content-Addressed Pour Programs

### Why Hash?

Without hashing, `ct pour sort-proof file.cell` would always create
`pour-sort-proof` as the pour-program ID. If you edit the .cell file and
re-pour, you'd collide with the old pour-program (cells already exist with
that ID). Options:

1. Delete old pour-program first (destructive, loses history)
2. Use a sequence number (stateful, fragile)
3. **Hash the file contents** (content-addressed, idempotent)

Option 3 is the right one. Same content → same program → already done.
Different content → different program → fresh parse. No cleanup needed.

### Hash Details

- Algorithm: SHA256
- Input: raw .cell file bytes (no normalization)
- Output: first 8 hex chars (4 bytes, ~4 billion values)
- Pour-program ID: `pour-{name}-{hash8}`
- Cell IDs: `pour-{name}-{hash8}-source`, `pour-{name}-{hash8}-parse`

---

## Oracles on the Parse Cell

Two deterministic oracles on the `parse` cell:

1. **`not_empty`** — the SQL output must not be blank
2. **`is_json_array`** — NOT used (SQL isn't JSON)

The `not_empty` check is the minimum gate. The real validation happens when
ct executes the SQL — if the INSERTs fail, ct reports the error. Future
oracles could check for syntactic SQL validity, but that's Phase B territory.

A semantic oracle "sql contains INSERT INTO cells" would be nice but isn't
enforceable deterministically without parsing SQL. Keep it simple for now.

---

## Backward Compatibility

- `ct pour name file.cell` with existing .sql file → **unchanged behavior**
  (executes the .sql directly, no pour-program created)
- `ct pour name file.cell` without .sql file → **new behavior**
  (creates pour-program, waits for piston)
- `ct repl name file.cell` → calls cmdPour first, then enters REPL
  (works with both old and new pour paths)

---

## Incremental Build & Test Plan

### Step 1: Pour-program template in Go

Write the Go code that INSERTs the 2-cell pour-program into Retort. Hard-code
the pour-prompt as a Go string constant. Test by manually inserting a
pour-program for sort-proof and checking the cells/yields/oracles rows.

### Step 2: Piston evaluates the pour-program

With the pour-program in Retort, run `ct repl` (or let jasper pick it up).
Verify the piston produces valid SQL for sort-proof.cell. Check the frozen
`parse.sql` yield value against the known-good sort-proof.sql.

### Step 3: Wire into ct pour

Add the hash + poll loop to cmdPour. Test: `ct pour sort-proof sort-proof.cell`
without a .sql file, with a piston running. Verify it waits, the piston
parses, ct executes the SQL, and sort-proof appears in Retort.

### Step 4: Cache hit test

Run the same `ct pour` command again. Verify it detects the frozen yield
and skips (instant).

### Step 5: Changed file test

Edit the .cell file. Run `ct pour` again. Verify new hash → new pour-program
→ fresh parse.

### Step 6: Test with research-index

Pour a more complex program (research-index.cell) via piston parsing.
Verify all 7 cells appear correctly in Retort.

---

## Relationship to Cell-Zero

This is the first cell in cell-zero's bootstrap sequence:

1. **Pour-as-cell** (this design) — parsing is a Cell operation ← WE ARE HERE
2. **Eval-step-as-cell** — the claim→dispatch→evaluate→submit loop as cells
3. **Oracle-as-cell** — verification as cells that can themselves be verified
4. **Cell-zero** — the full evaluator as a .cell program running on itself

Each step makes more of the runtime into Cell programs that the piston
evaluates. Pour is the natural starting point because it's the entry point
— programs can't run until they're parsed and loaded.

---

## Open Questions (Deferred)

1. **Multi-statement SQL execution** — the piston's SQL output may contain
   multiple INSERT statements separated by `;`. The Go mysql driver handles
   this with `multiStatements=true` (already enabled). But DOLT_COMMIT at
   the end may fail with "nothing to commit" if auto-commit is on. Handle
   the same way as current cmdPour (ignore "nothing to commit" errors).

2. **Pour-program cleanup** — old pour-programs accumulate. Not a problem
   for now (they're small, Dolt handles history). Future: a reaper that
   cleans up pour-programs older than N days.

3. **Streaming parse** — for large .cell files, the literal value in the
   `source` cell could be very long (VARCHAR(4096) limit in cells.body).
   The yields table uses TEXT which has no practical limit, but the cell
   body does. For now: the source text goes in the yield, not the body.
   The body just says "literal:" and the yield holds the full text.

4. **Phase B fallback** — if no piston is running, ct pour hangs forever
   waiting. Future: add a timeout flag (`--timeout 30s`) and/or a built-in
   deterministic parser (Phase B) as fallback.
