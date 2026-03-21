package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"
	"os"
	"strings"

	_ "github.com/go-sql-driver/mysql"
)

const usage = `ct — Cell Tool (Lua runtime for the Cell dataflow language)

Usage:
  ct pour <name> <file.lua>                           Load a Lua cell program into the retort
  ct run <name> <file.lua>                            Pour + run a cell program (everything in Lua)
  ct lint <file.lua>                                  Validate a Lua cell program
  ct piston                                           Autonomous piston loop
  ct piston <program-id>                              Piston for one program
  ct next [--wait] [--model <hint>] [<program-id>]    Claim next ready cell, print prompt, exit
  ct submit <program-id> <cell> <field> <value>       Submit a soft cell result
  ct watch [<program-id>]                             Live dashboard (2s refresh)
  ct status <program-id>                              Show program state
  ct frames <program-id>                              Show frames (generation, status)
  ct yields <program-id>                              Show frozen yields
  ct history <program-id>                             Show execution history
  ct graph <program-id>                               Show DAG (dependency graph)
  ct thaw <program-id> <cell>                         Thaw cell + dependents
  ct reset <program-id>                               Reset program

Cell programs are Lua. See examples/cell-zero.lua.
Design doc: docs/plans/2026-03-21-lua-substrate-design.md

Environment:
  RETORT_DSN   Dolt DSN (default: root@tcp(127.0.0.1:3308)/retort)
`

func main() {
	if len(os.Args) < 2 {
		fmt.Print(usage)
		os.Exit(1)
	}

	dsn := os.Getenv("RETORT_DSN")
	if dsn == "" {
		dsn = "root@tcp(127.0.0.1:3308)/retort"
	}

	db, err := sql.Open("mysql", dsn+"?multiStatements=true&parseTime=true&tls=false")
	if err != nil {
		fatal("connect: %v", err)
	}
	defer db.Close()
	if err := db.Ping(); err != nil {
		// Auto-init: if retort database doesn't exist, create it
		if strings.Contains(err.Error(), "database not found") {
			initDSN := strings.Replace(dsn, "/retort", "/", 1)
			if initDB, e2 := sql.Open("mysql", initDSN+"?multiStatements=true&parseTime=true&tls=false"); e2 == nil {
				defer initDB.Close()
				if autoInitRetort(initDB) {
					// Retry ping after init
					if err := db.Ping(); err != nil {
						fatal("ping after init: %v", err)
					}
				} else {
					fatal("ping: %v", err)
				}
			} else {
				fatal("ping: %v", err)
			}
		} else {
			fatal("ping: %v", err)
		}
	}

	cmd := os.Args[1]
	args := os.Args[2:]

	// Commands that don't need a DB connection
	if cmd == "lint" {
		need(args, 1, "ct lint <file.lua>")
		cmdLint(args[0])
		return
	}

	switch cmd {
	case "piston":
		progID := ""
		if len(args) > 0 {
			progID = args[0]
		}
		cmdPiston(db, progID)
	case "next":
		progID := ""
		wait := false
		modelHint := ""
		for i := 0; i < len(args); i++ {
			if args[i] == "--wait" {
				wait = true
			} else if args[i] == "--model" && i+1 < len(args) {
				i++
				modelHint = args[i]
			} else {
				progID = args[i]
			}
		}
		cmdNext(db, progID, wait, modelHint)
	case "watch":
		progID := ""
		if len(args) > 0 {
			progID = args[0]
		}
		cmdWatch(db, progID)
	case "pour":
		need(args, 2, "ct pour <name> <file.lua>")
		cmdPour(db, args[0], args[1])
	case "run":
		need(args, 2, "ct run <name> <file.lua>")
		cmdRunLua(db, args[0], args[1])
	case "submit":
		need(args, 4, "ct submit <program-id> <cell> <field> <value>")
		cmdSubmit(db, args[0], args[1], args[2], args[3])
	case "status":
		need(args, 1, "ct status <program-id>")
		cmdStatus(db, args[0])
	case "frames":
		need(args, 1, "ct frames <program-id>")
		cmdFrames(db, args[0])
	case "yields":
		need(args, 1, "ct yields <program-id>")
		cmdYields(db, args[0])
	case "history":
		need(args, 1, "ct history <program-id>")
		cmdHistory(db, args[0])
	case "graph":
		need(args, 1, "ct graph <program-id>")
		cmdGraph(db, args[0])
	case "thaw":
		need(args, 2, "ct thaw <program-id> <cell>")
		cmdThaw(db, args[0], args[1])
	case "reset":
		need(args, 1, "ct reset <program-id>")
		cmdReset(db, args[0])
	default:
		fatal("unknown command: %s", cmd)
	}
}

func need(args []string, n int, u string) {
	if len(args) < n {
		fatal("usage: %s", u)
	}
}

func fatal(f string, a ...any) {
	fmt.Fprintf(os.Stderr, "ct: "+f+"\n", a...)
	os.Exit(1)
}

func trunc(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

// wordWrap wraps text to the given width, breaking at word boundaries.
// Preserves existing newlines.
func wordWrap(s string, width int) string {
	if width <= 0 {
		return s
	}
	var result strings.Builder
	for i, paragraph := range strings.Split(s, "\n") {
		if i > 0 {
			result.WriteByte('\n')
		}
		col := 0
		words := strings.Fields(paragraph)
		for j, w := range words {
			wLen := len(w)
			if col+wLen > width && col > 0 {
				result.WriteByte('\n')
				col = 0
			} else if j > 0 && col > 0 {
				result.WriteByte(' ')
				col++
			}
			result.WriteString(w)
			col += wLen
		}
	}
	return result.String()
}

func genPistonID() string {
	b := make([]byte, 8)
	rand.Read(b)
	return fmt.Sprintf("piston-%s", hex.EncodeToString(b))
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
