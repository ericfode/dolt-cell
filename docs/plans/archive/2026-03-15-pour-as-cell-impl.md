# Pour-as-Cell Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `ct pour` create a 2-cell pour-program in Retort so the running piston parses .cell files as regular soft cell evaluation.

**Architecture:** cmdPour checks for .sql (backward compat), else computes SHA256 hash of .cell contents, creates a content-addressed pour-program (source + parse cells), polls for the piston to freeze the parse.sql yield, then executes the resulting SQL.

**Tech Stack:** Go, Dolt (MySQL wire protocol), SHA256 hashing

---

### Task 1: Add imports and pour-prompt constant

**Files:**
- Modify: `cmd/ct/main.go:1-13` (imports)
- Modify: `cmd/ct/main.go` (add constant after imports)

**Step 1: Add crypto/sha256 and encoding/hex imports**

```go
import (
	"bufio"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
)
```

**Step 2: Add pourPrompt constant after imports (before usage)**

The condensed pour-prompt (2866 bytes, fits VARCHAR(4096)):

```go
const pourPrompt = `Parse Cell program «name» into SQL INSERTs for the Retort schema.
...
«text»`
```

(Full text in implementation — condensed from tools/pour-prompt.md)

**Step 3: Build**

Run: `cd cmd/ct && go build -o ../../ct .`
Expected: exit 0

**Step 4: Commit**

```
feat: add pour-prompt constant for pour-as-cell
```

---

### Task 2: Rewrite cmdPour with hash + pour-program creation

**Files:**
- Modify: `cmd/ct/main.go` (cmdPour function, lines 281-304)

**Step 1: Rewrite cmdPour**

New flow:
1. Read .cell file, try .sql first (backward compat)
2. If no .sql: compute SHA256 → hash8
3. Pour-program ID = `pour-{name}-{hash8}`
4. Check if parse yield already frozen → read + execute (cache hit)
5. If not: INSERT the 2-cell pour-program into Retort
6. Poll every 2s for parse.sql yield to freeze
7. Read frozen yield, execute SQL, report

Key details:
- source cell: id=`{pourProg}-source`, body=`literal:` (text goes in yield)
- parse cell: id=`{pourProg}-parse`, body=pourPrompt constant
- source yields: text (the .cell contents), name (the program name)
- parse yield: sql
- parse oracle: not_empty (deterministic)
- Poll loop: 60 iterations × 2s = 2 minute timeout

**Step 2: Build**

Run: `cd cmd/ct && go build -o ../../ct .`
Expected: exit 0

**Step 3: Commit**

```
feat: ct pour creates pour-program for piston-driven parsing
```

---

### Task 3: Test — piston parses sort-proof.cell

**Step 1: Delete sort-proof.sql temporarily (rename it)**

```bash
mv examples/sort-proof.sql examples/sort-proof.sql.bak
```

**Step 2: Reset retort state**

```bash
RETORT_DSN="root@tcp(127.0.0.1:3307)/retort" ./ct reset sort-proof
```

**Step 3: Run ct pour (it will create pour-program and wait)**

In one terminal:
```bash
RETORT_DSN="root@tcp(127.0.0.1:3307)/retort" ./ct pour sort-proof examples/sort-proof.cell
```

This should print "waiting for piston to parse..." and poll.

**Step 4: In another terminal, run the piston**

```bash
printf '<piston answers here>' | RETORT_DSN="root@tcp(127.0.0.1:3307)/retort" ./ct repl
```

Or let the jasper polecat handle it.

**Step 5: Verify pour completes**

Expected: ct pour prints "✓ sort-proof: 3 cells"

**Step 6: Verify the program works**

```bash
printf '[1,2,3,4,7,9]\nDone.\n' | RETORT_DSN="root@tcp(127.0.0.1:3307)/retort" ./ct repl sort-proof
```

Expected: 3/3 frozen

**Step 7: Restore .sql file, commit**

```bash
mv examples/sort-proof.sql.bak examples/sort-proof.sql
```

---

### Task 4: Test — cache hit (same file = skip)

**Step 1: Run ct pour again with same file**

```bash
RETORT_DSN="root@tcp(127.0.0.1:3307)/retort" ./ct pour sort-proof examples/sort-proof.cell
```

Expected: instant completion (no waiting), prints "✓ sort-proof: 3 cells"
(The pour-program's parse.sql yield is already frozen from Task 3)

---

### Task 5: Test — changed file = fresh parse

**Step 1: Create a modified .cell file**

```bash
cp examples/sort-proof.cell /tmp/sort-proof-v2.cell
echo '⊢ extra\n  yield bonus ≡ hello' >> /tmp/sort-proof-v2.cell
```

**Step 2: Pour the modified version**

```bash
RETORT_DSN="root@tcp(127.0.0.1:3307)/retort" ./ct pour sort-v2 /tmp/sort-proof-v2.cell
```

Expected: new hash → new pour-program → waits for piston → completes

---

### Task 6: Test — complex program (research-index.cell)

**Step 1: Remove research-index.sql temporarily**

```bash
mv examples/research-index.sql examples/research-index.sql.bak
```

**Step 2: Pour via piston**

```bash
RETORT_DSN="root@tcp(127.0.0.1:3307)/retort" ./ct reset research-index
RETORT_DSN="root@tcp(127.0.0.1:3307)/retort" ./ct pour research-index examples/research-index.cell
```

**Step 3: Verify 7 cells poured correctly**

```bash
RETORT_DSN="root@tcp(127.0.0.1:3307)/retort" ./ct status research-index
```

Expected: 7 cells, correct dependencies

**Step 4: Restore and commit**

```bash
mv examples/research-index.sql.bak examples/research-index.sql
git commit -am "feat: pour-as-cell verified end-to-end"
```
