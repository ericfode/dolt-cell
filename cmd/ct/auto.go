package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// cmdAuto runs an autonomous piston that uses Claude API for soft cells.
func cmdAuto(db *sql.DB, progID string, maxCalls int, model string) {
	apiKey := os.Getenv("ANTHROPIC_API_KEY")
	if apiKey == "" {
		fatal("ANTHROPIC_API_KEY not set")
	}

	pistonID := "auto-" + genPistonID()
	mustExecDB(db, "DELETE FROM pistons WHERE id = ?", pistonID)
	mustExecDB(db,
		"INSERT INTO pistons (id, program_id, model_hint, started_at, last_heartbeat, status, cells_completed) VALUES (?, ?, ?, NOW(), NOW(), 'active', 0)",
		pistonID, progID, model)
	defer func() {
		mustExecDB(db, "UPDATE pistons SET status = 'dead' WHERE id = ?", pistonID)
	}()

	calls := 0
	step := 0

	for {
		step++
		if calls >= maxCalls {
			fmt.Printf("\n━━ budget exhausted (%d/%d calls) ━━\n", calls, maxCalls)
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

			// Build yield instructions
			yieldInstr := ""
			if len(yields) == 1 {
				yieldInstr = fmt.Sprintf("\n\nRespond with ONLY the value for the yield field '%s'. No explanation, no labels, just the value.", yields[0])
			} else {
				yieldInstr = "\n\nRespond with the following fields, each on its own line in the format FIELD_NAME: value\n"
				for _, y := range yields {
					yieldInstr += fmt.Sprintf("- %s\n", y)
				}
			}

			// Call Claude API
			calls++
			fmt.Printf("  → calling %s (%d/%d)...\n", model, calls, maxCalls)

			response, err := callClaude(apiKey, model, prompt+yieldInstr)
			if err != nil {
				fmt.Printf("  ✗ API error: %v\n", err)
				// Release claim and continue
				mustExecDB(db, "DELETE FROM cell_claims WHERE cell_id = ?", es.cellID)
				mustExecDB(db, "UPDATE cells SET state = 'declared', computing_since = NULL, assigned_piston = NULL WHERE id = ?", es.cellID)
				continue
			}

			fmt.Printf("  ← %d chars\n", len(response))

			// Parse response into yield values
			values := parseYieldResponse(response, yields)

			// Submit each yield
			for _, y := range yields {
				val := values[y]
				if val == "" {
					val = response // fallback: entire response for single-yield
				}

				for attempt := 1; attempt <= 3; attempt++ {
					result, msg := replSubmit(db, es.progID, es.cellName, y, val)
					if result == "ok" {
						fmt.Printf("  ■ %s.%s frozen\n", es.cellName, y)
						break
					} else if result == "oracle_fail" && attempt < 3 {
						fmt.Printf("  ✗ oracle_fail: %s (retry %d/3)\n", msg, attempt)
						// Retry with feedback
						calls++
						retryPrompt := fmt.Sprintf("%s\n\nYour previous answer failed validation: %s\nPlease revise your answer for field '%s'.", prompt, msg, y)
						response, err = callClaude(apiKey, model, retryPrompt)
						if err != nil {
							fmt.Printf("  ✗ retry API error: %v\n", err)
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

// parseYieldResponse extracts yield values from LLM response.
func parseYieldResponse(response string, yields []string) map[string]string {
	values := make(map[string]string)

	if len(yields) == 1 {
		values[yields[0]] = strings.TrimSpace(response)
		return values
	}

	// Try FIELD_NAME: value format
	lines := strings.Split(response, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		for _, y := range yields {
			prefix := y + ":"
			if strings.HasPrefix(line, prefix) {
				values[y] = strings.TrimSpace(strings.TrimPrefix(line, prefix))
			}
			// Also try FIELD_NAME = value
			prefix2 := y + " ="
			if strings.HasPrefix(line, prefix2) {
				values[y] = strings.TrimSpace(strings.TrimPrefix(line, prefix2))
			}
		}
	}

	return values
}

// callClaude calls the Anthropic Messages API.
func callClaude(apiKey, model, prompt string) (string, error) {
	body := map[string]interface{}{
		"model":      model,
		"max_tokens": 4096,
		"messages": []map[string]string{
			{"role": "user", "content": prompt},
		},
	}

	jsonBody, err := json.Marshal(body)
	if err != nil {
		return "", fmt.Errorf("marshal: %v", err)
	}

	req, err := http.NewRequest("POST", "https://api.anthropic.com/v1/messages", bytes.NewReader(jsonBody))
	if err != nil {
		return "", fmt.Errorf("request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", apiKey)
	req.Header.Set("anthropic-version", "2023-06-01")

	client := &http.Client{Timeout: 120 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("http: %v", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read: %v", err)
	}

	if resp.StatusCode != 200 {
		return "", fmt.Errorf("API %d: %s", resp.StatusCode, string(respBody))
	}

	var result struct {
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
	}
	if err := json.Unmarshal(respBody, &result); err != nil {
		return "", fmt.Errorf("unmarshal: %v", err)
	}
	if len(result.Content) == 0 {
		return "", fmt.Errorf("empty response")
	}

	return result.Content[0].Text, nil
}
