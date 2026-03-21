package main

// emit.go — Event emission for Gas City integration.
//
// When ct dispatches a soft cell (needs LLM evaluation), it emits a
// "cell.needs_piston" event to Gas City's event bus. The Gas City order
// system watches for this event and dispatches a piston polecat via the
// mol-cell-piston formula.
//
// Events are emitted via `gc event emit` (best-effort, always exits 0).
// This keeps ct decoupled from Gas City internals — it just shells out.

import (
	"encoding/json"
	"fmt"
	"os/exec"
)

// emitCellEvent emits a cell event to Gas City's event bus.
// Best-effort: errors are logged but never fatal.
func emitCellEvent(eventType, program, cell, message string, extra map[string]string) {
	payload := map[string]string{
		"program": program,
		"cell":    cell,
	}
	for k, v := range extra {
		payload[k] = v
	}

	payloadJSON, _ := json.Marshal(payload)

	cmd := exec.Command("gc", "event", "emit", eventType,
		"--actor", "ct",
		"--subject", program+"/"+cell,
		"--message", message,
		"--payload", string(payloadJSON),
	)

	if out, err := cmd.CombinedOutput(); err != nil {
		fmt.Printf("  [event] emit %s failed: %v (%s)\n", eventType, err, string(out))
	}
}

// emitNeedsPiston emits a "cell.needs_piston" event when a soft cell
// is dispatched and needs LLM evaluation.
func emitNeedsPiston(program, cell, bodyType string) {
	emitCellEvent("cell.needs_piston", program, cell,
		fmt.Sprintf("soft cell %s/%s needs LLM evaluation", program, cell),
		map[string]string{"body_type": bodyType},
	)
}

// emitYieldFrozen emits a "cell.yield_frozen" event when a yield is
// successfully submitted and frozen.
func emitYieldFrozen(program, cell, field string) {
	emitCellEvent("cell.yield_frozen", program, cell,
		fmt.Sprintf("yield %s/%s.%s frozen", program, cell, field),
		map[string]string{"field": field},
	)
}

// emitProgramComplete emits a "cell.program_complete" event when all
// non-stem cells in a program are frozen.
func emitProgramComplete(program string) {
	emitCellEvent("cell.program_complete", program, "",
		fmt.Sprintf("program %s complete", program),
		nil,
	)
}
