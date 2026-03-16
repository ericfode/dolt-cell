package main

import (
	"database/sql"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// cmdAuto runs an autonomous piston loop using the piston pattern.
// Soft cells are evaluated by invoking an LLM piston subprocess
// (default: claude CLI with the piston system-prompt as context).
//
// The piston pattern: claim → dispatch to piston → piston evaluates → ct submit.
// This keeps evaluation going through the piston architecture rather than
// bypassing it with direct API calls.
func cmdAuto(db *sql.DB, progID string, maxSteps int, pistonCmd string) {
	pistonID := "auto-" + genPistonID()
	mustExecDB(db, "DELETE FROM pistons WHERE id = ?", pistonID)
	mustExecDB(db,
		"INSERT INTO pistons (id, program_id, model_hint, started_at, last_heartbeat, status, cells_completed) VALUES (?, ?, NULL, NOW(), NOW(), 'active', 0)",
		pistonID, progID)
	defer func() {
		mustExecDB(db, "UPDATE pistons SET status = 'dead' WHERE id = ?", pistonID)
	}()

	step := 0
	for {
		step++
		if step > maxSteps {
			fmt.Printf("\n━━ step limit reached (%d) ━━\n", maxSteps)
			break
		}

		mustExecDB(db, "UPDATE pistons SET last_heartbeat = NOW() WHERE id = ?", pistonID)
		es := replEvalStep(db, progID, pistonID, "")

		switch es.action {
		case "complete":
			fmt.Printf("\n━━ %s · COMPLETE ━━\n", progID)
			cmdYields(db, progID)
			return

		case "quiescent":
			fmt.Printf("\n━━ %s · quiescent ━━\n", progID)
			cmdYields(db, progID)
			return

		case "evaluated":
			fmt.Printf("  ■ %s frozen (hard)\n", es.cellName)
			continue

		case "dispatch":
			// Soft cell — dispatch to piston subprocess
			inputs := resolveInputs(db, es.progID, es.cellName)
			prompt := interpolateBody(es.body, inputs)
			yields := getYieldFields(db, es.progID, es.cellName)

			fmt.Printf("──── step %d: %s ────\n", step, es.cellName)
			for k, v := range inputs {
				if strings.Contains(k, "→") {
					fmt.Printf("  given %s ≡ %s\n", k, trunc(v, 50))
				}
			}
			fmt.Printf("  ∴ %s\n", trunc(prompt, 100))
			fmt.Printf("  yields: %s\n", strings.Join(yields, ", "))

			// Build the piston evaluation prompt
			evalPrompt := buildPistonPrompt(prompt, yields)

			// Invoke piston subprocess
			fmt.Printf("  → piston: %s\n", pistonCmd)
			response, err := invokePiston(pistonCmd, evalPrompt)
			if err != nil {
				fmt.Printf("  ✗ piston error: %v\n", err)
				// Release claim so cell can be retried
				mustExecDB(db, "DELETE FROM cell_claims WHERE cell_id = ?", es.cellID)
				mustExecDB(db, "UPDATE cells SET state = 'declared', computing_since = NULL, assigned_piston = NULL WHERE id = ?", es.cellID)
				continue
			}

			fmt.Printf("  ← %d chars\n", len(response))

			// Parse response into yield values and submit
			values := parseYieldResponse(response, yields)
			for _, y := range yields {
				val := values[y]
				if val == "" {
					val = strings.TrimSpace(response)
				}

				for attempt := 1; attempt <= 3; attempt++ {
					result, msg := replSubmit(db, es.progID, es.cellName, y, val)
					if result == "ok" {
						fmt.Printf("  ■ %s.%s frozen\n", es.cellName, y)
						break
					} else if result == "oracle_fail" && attempt < 3 {
						fmt.Printf("  ✗ oracle_fail: %s (retry %d/3)\n", msg, attempt)
						retryPrompt := fmt.Sprintf("%s\n\nYour previous answer failed validation: %s\nRevise your answer for field '%s'.", evalPrompt, msg, y)
						response, err = invokePiston(pistonCmd, retryPrompt)
						if err != nil {
							fmt.Printf("  ✗ retry piston error: %v\n", err)
							break
						}
						val = strings.TrimSpace(response)
					} else {
						fmt.Printf("  ✗ %s: %s\n", result, msg)
						break
					}
				}
			}
		}
	}
}

// buildPistonPrompt creates the evaluation prompt for the piston subprocess.
func buildPistonPrompt(body string, yields []string) string {
	var sb strings.Builder
	sb.WriteString(body)
	sb.WriteString("\n\n")
	if len(yields) == 1 {
		sb.WriteString(fmt.Sprintf("Respond with ONLY the value for '%s'. No labels, no explanation.", yields[0]))
	} else {
		sb.WriteString("Respond with each field on its own line in the format FIELD: value\n")
		for _, y := range yields {
			sb.WriteString(fmt.Sprintf("- %s\n", y))
		}
	}
	return sb.String()
}

// invokePiston calls the piston command with the prompt on stdin.
// The piston command should read stdin and write the response to stdout.
//
// Default piston commands:
//   claude --print "PROMPT"       — Claude Code CLI
//   echo "PROMPT" | claude -p     — piped mode
//   cat                           — manual (for testing)
func invokePiston(pistonCmd, prompt string) (string, error) {
	parts := strings.Fields(pistonCmd)
	if len(parts) == 0 {
		return "", fmt.Errorf("empty piston command")
	}

	cmd := exec.Command(parts[0], parts[1:]...)
	cmd.Stdin = strings.NewReader(prompt)
	cmd.Stderr = os.Stderr

	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("%s: %v", pistonCmd, err)
	}

	return strings.TrimSpace(string(out)), nil
}

// parseYieldResponse extracts yield values from piston response.
func parseYieldResponse(response string, yields []string) map[string]string {
	values := make(map[string]string)

	if len(yields) == 1 {
		values[yields[0]] = strings.TrimSpace(response)
		return values
	}

	// Try FIELD: value or FIELD = value format
	lines := strings.Split(response, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		for _, y := range yields {
			for _, sep := range []string{": ", " = ", "="} {
				prefix := y + sep
				if strings.HasPrefix(line, prefix) {
					values[y] = strings.TrimSpace(strings.TrimPrefix(line, prefix))
				}
			}
		}
	}

	return values
}
