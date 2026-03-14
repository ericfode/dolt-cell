-- Cell Heartbeat/Lease Schema Additions and Stored Procedures
--
-- Addresses: stuck computing cells when pistons die mid-evaluation.
-- When cell_eval_step() claims a cell (state='computing'), it records
-- computing_since and assigned_piston. If the piston dies, cell_reap_stale()
-- resets the cell back to 'declared' so another piston can pick it up.
--
-- References:
--   - Design: docs/plans/2026-03-14-cell-repl-design-v2.md
--   - Review: docs/reviews/kai-v2-review.md (Part 5: Session Death and Recovery)
--   - Bead: do-6lq
--
-- Prerequisites:
--   - Retort base schema (cells, yields, givens, oracles, trace tables)
--   - Base cells table with state ENUM including 'computing' and 'declared'

-- ---------------------------------------------------------------------------
-- 1. Schema additions to the cells table
-- ---------------------------------------------------------------------------

-- Track when a cell was claimed and by whom.
-- These columns enable timeout-based lease expiry without external heartbeats.
ALTER TABLE cells
  ADD COLUMN computing_since DATETIME DEFAULT NULL
    COMMENT 'Timestamp when this cell entered computing state. NULL when not computing.',
  ADD COLUMN assigned_piston VARCHAR(255) DEFAULT NULL
    COMMENT 'Identifier of the piston that claimed this cell. NULL when not computing.';

-- Index for the reaper query: find stale computing cells efficiently.
CREATE INDEX idx_cells_computing_since
  ON cells (state, computing_since)
  COMMENT 'Supports cell_reap_stale() scanning for timed-out computing cells';

-- ---------------------------------------------------------------------------
-- 2. Pistons registry table
-- ---------------------------------------------------------------------------

-- Tracks active LLM pistons. Pistons register on startup and update their
-- heartbeat periodically. Stale heartbeats indicate dead pistons.
CREATE TABLE IF NOT EXISTS pistons (
  id            VARCHAR(255) PRIMARY KEY
                COMMENT 'Unique piston identifier (e.g., session ID or agent name)',
  program_id    VARCHAR(255) NOT NULL
                COMMENT 'The program this piston is working on',
  model_hint    VARCHAR(64) DEFAULT NULL
                COMMENT 'Model affinity filter (e.g., haiku, opus). NULL = any.',
  started_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                COMMENT 'When this piston was spawned',
  last_heartbeat DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                COMMENT 'Last time this piston reported alive',
  status        ENUM('active', 'draining', 'dead') NOT NULL DEFAULT 'active'
                COMMENT 'active=running, draining=finishing current cell, dead=terminated',
  cells_completed INT NOT NULL DEFAULT 0
                COMMENT 'Count of cells this piston has successfully evaluated'
);

CREATE INDEX idx_pistons_heartbeat
  ON pistons (status, last_heartbeat)
  COMMENT 'Supports stale piston detection';

CREATE INDEX idx_pistons_program
  ON pistons (program_id, status)
  COMMENT 'Supports orphaned program detection';

-- ---------------------------------------------------------------------------
-- 3. cell_reap_stale() — Reset stuck computing cells
-- ---------------------------------------------------------------------------

-- Resets cells that have been in 'computing' state longer than the given
-- timeout. This handles piston death: the cell was claimed but never submitted.
--
-- Key semantics (from Kai v2 review §5.3):
--   - Do NOT increment retry_count. Piston death is not an evaluation failure.
--   - Clear partial tentative values from dead evaluations.
--   - Log recovery to the trace table.
--   - Detect orphaned programs (programs with no active pistons).
--
-- Parameters:
--   timeout_minutes  — Minutes after which a computing cell is considered stuck.
--                      Default: 10. Tune based on expected soft cell eval time.
--
-- Returns:
--   Result set with columns:
--     reaped_cells     — Number of cells reset to declared
--     cleared_yields   — Number of tentative yields cleared
--     orphaned_programs — Comma-separated list of program_ids with no active pistons
--     stale_pistons    — Number of pistons marked dead

DELIMITER //

CREATE PROCEDURE cell_reap_stale(IN timeout_minutes INT)
BEGIN
  DECLARE v_reaped INT DEFAULT 0;
  DECLARE v_cleared INT DEFAULT 0;
  DECLARE v_stale_pistons INT DEFAULT 0;
  DECLARE v_orphaned TEXT DEFAULT '';
  DECLARE v_now DATETIME;

  -- Use a consistent timestamp for the entire operation
  SET v_now = NOW();

  -- Default timeout: 10 minutes
  IF timeout_minutes IS NULL OR timeout_minutes <= 0 THEN
    SET timeout_minutes = 10;
  END IF;

  -- -----------------------------------------------------------------------
  -- Step 1: Mark stale pistons as dead
  -- -----------------------------------------------------------------------
  -- A piston is stale if its heartbeat is older than the timeout.
  -- This is separate from cell reaping: a piston can be alive but its cell
  -- might still be stuck (e.g., piston crashed between heartbeat and submit).

  UPDATE pistons
  SET status = 'dead'
  WHERE status = 'active'
    AND last_heartbeat < v_now - INTERVAL timeout_minutes MINUTE;

  SET v_stale_pistons = ROW_COUNT();

  -- -----------------------------------------------------------------------
  -- Step 2: Clear tentative yields from stuck cells
  -- -----------------------------------------------------------------------
  -- If a piston wrote a partial tentative yield before dying, discard it.
  -- Only clear yields for cells that are about to be reaped.

  UPDATE yields y
  INNER JOIN cells c ON y.cell_id = c.id
  SET y.tentative_value = NULL
  WHERE c.state = 'computing'
    AND c.computing_since < v_now - INTERVAL timeout_minutes MINUTE
    AND y.is_frozen = 0
    AND y.tentative_value IS NOT NULL;

  SET v_cleared = ROW_COUNT();

  -- -----------------------------------------------------------------------
  -- Step 3: Log recovery to trace table
  -- -----------------------------------------------------------------------
  -- Insert a trace row for each cell being reaped, before resetting state.
  -- This preserves the forensic record of what happened.

  INSERT INTO trace (cell_id, program_id, event_type, event_data, created_at)
  SELECT
    c.id,
    c.program_id,
    'reap_stale',
    CONCAT('{"reason":"piston_timeout","assigned_piston":"',
           COALESCE(c.assigned_piston, 'unknown'),
           '","computing_since":"',
           COALESCE(CAST(c.computing_since AS CHAR), 'null'),
           '","timeout_minutes":', timeout_minutes, '}'),
    v_now
  FROM cells c
  WHERE c.state = 'computing'
    AND c.computing_since < v_now - INTERVAL timeout_minutes MINUTE;

  -- -----------------------------------------------------------------------
  -- Step 4: Reset stuck cells back to declared
  -- -----------------------------------------------------------------------
  -- The core reap operation. Cells go back to 'declared' so they appear
  -- in ready_cells again and another piston can pick them up.
  --
  -- IMPORTANT: retry_count is NOT incremented. Piston death is infrastructure
  -- failure, not evaluation failure. The cell hasn't been evaluated.

  UPDATE cells
  SET state = 'declared',
      computing_since = NULL,
      assigned_piston = NULL
  WHERE state = 'computing'
    AND computing_since < v_now - INTERVAL timeout_minutes MINUTE;

  SET v_reaped = ROW_COUNT();

  -- -----------------------------------------------------------------------
  -- Step 5: Detect orphaned programs
  -- -----------------------------------------------------------------------
  -- A program is orphaned if it has cells in 'declared' state (work to do)
  -- but no active pistons assigned to it. This signals that a piston needs
  -- to be respawned.

  SELECT GROUP_CONCAT(DISTINCT sub.program_id SEPARATOR ',')
  INTO v_orphaned
  FROM (
    SELECT c.program_id
    FROM cells c
    WHERE c.state = 'declared'
      AND c.program_id NOT IN (
        SELECT p.program_id
        FROM pistons p
        WHERE p.status = 'active'
      )
    GROUP BY c.program_id
  ) sub;

  IF v_orphaned IS NULL THEN
    SET v_orphaned = '';
  END IF;

  -- -----------------------------------------------------------------------
  -- Return summary
  -- -----------------------------------------------------------------------
  SELECT
    v_reaped AS reaped_cells,
    v_cleared AS cleared_yields,
    v_orphaned AS orphaned_programs,
    v_stale_pistons AS stale_pistons;
END //

DELIMITER ;

-- ---------------------------------------------------------------------------
-- 4. Piston lifecycle helpers
-- ---------------------------------------------------------------------------

-- Register a new piston when it starts up.
DELIMITER //

CREATE PROCEDURE piston_register(
  IN p_id VARCHAR(255),
  IN p_program_id VARCHAR(255),
  IN p_model_hint VARCHAR(64)
)
BEGIN
  INSERT INTO pistons (id, program_id, model_hint, started_at, last_heartbeat, status)
  VALUES (p_id, p_program_id, p_model_hint, NOW(), NOW(), 'active')
  ON DUPLICATE KEY UPDATE
    program_id = p_program_id,
    model_hint = p_model_hint,
    started_at = NOW(),
    last_heartbeat = NOW(),
    status = 'active',
    cells_completed = 0;
END //

DELIMITER ;

-- Update piston heartbeat. Called periodically by each piston.
DELIMITER //

CREATE PROCEDURE piston_heartbeat(IN p_id VARCHAR(255))
BEGIN
  UPDATE pistons
  SET last_heartbeat = NOW()
  WHERE id = p_id AND status = 'active';

  -- Return 0 rows affected if piston was already marked dead (reaper ran).
  -- The piston should check ROW_COUNT() and re-register if needed.
  SELECT ROW_COUNT() AS updated;
END //

DELIMITER ;

-- Gracefully deregister a piston when it shuts down cleanly.
DELIMITER //

CREATE PROCEDURE piston_deregister(IN p_id VARCHAR(255))
BEGIN
  -- Release any cells this piston had claimed (shouldn't happen if clean
  -- shutdown, but defensive).
  UPDATE cells
  SET state = 'declared',
      computing_since = NULL,
      assigned_piston = NULL
  WHERE assigned_piston = p_id
    AND state = 'computing';

  UPDATE pistons
  SET status = 'dead'
  WHERE id = p_id;
END //

DELIMITER ;

-- ---------------------------------------------------------------------------
-- 5. Integration: cell_eval_step claim snippet
-- ---------------------------------------------------------------------------
-- This is NOT a standalone procedure — it shows the claim logic that
-- cell_eval_step() must use when transitioning a cell to 'computing'.
--
-- The full cell_eval_step() procedure is defined in the PoC (do-h46).
-- This snippet documents the heartbeat integration point.
--
-- When cell_eval_step() claims a cell:
--
--   UPDATE cells
--   SET state = 'computing',
--       computing_since = NOW(),
--       assigned_piston = @piston_id
--   WHERE id = @ready_cell_id
--     AND state = 'declared';
--
-- When cell_submit() completes successfully:
--
--   UPDATE cells
--   SET state = 'frozen',       -- or 'tentative' if oracles pending
--       computing_since = NULL,
--       assigned_piston = NULL
--   WHERE id = @cell_id;
--
--   UPDATE pistons
--   SET cells_completed = cells_completed + 1,
--       last_heartbeat = NOW()
--   WHERE id = @piston_id;
