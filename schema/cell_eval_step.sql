-- cell_eval_step: Find a ready cell, claim it atomically, return dispatch info
--
-- This procedure replaces the SELECT FOR UPDATE pattern from the v2 design doc.
-- Instead of row-level locking (which Dolt doesn't support), it uses INSERT-based
-- claiming via the cell_claims table. First piston wins; others retry.
--
-- Parameters:
--   p_program_id  - The program to find work in
--   p_piston_id   - The calling piston's identifier
--
-- Returns a single-row result set:
--   action          - 'dispatch' | 'quiescent' | 'complete'
--   cell_id         - The claimed cell's ID (NULL if not dispatch)
--   cell_name       - The cell's human-readable name
--   body            - The cell body (prompt text for soft, executor ref for hard)
--   body_type       - 'soft' | 'hard'
--   model_hint      - Preferred model for soft cells (NULL = default)
--   resolved_inputs - JSON object of resolved given values
--
-- Claiming protocol:
--   1. Query ready_cells view for unclaimed cells
--   2. For each candidate, INSERT IGNORE into cell_claims
--   3. Check ROW_COUNT(): 1 = claimed, 0 = another piston won, try next
--   4. On claim success, UPDATE cells.state = 'computing', return dispatch
--   5. If no cells claimable, return 'quiescent'
--
-- Prerequisites:
--   - cells table (Retort schema)
--   - yields table (Retort schema)
--   - givens table (Retort schema)
--   - ready_cells view (Retort schema)
--   - cell_claims table (this package)
--
-- Bead: do-i5p

DELIMITER //

DROP PROCEDURE IF EXISTS cell_eval_step //

CREATE PROCEDURE cell_eval_step(
    IN p_program_id VARCHAR(255),
    IN p_piston_id  VARCHAR(255)
)
BEGIN
    DECLARE v_cell_id    VARCHAR(255) DEFAULT NULL;
    DECLARE v_cell_name  VARCHAR(255);
    DECLARE v_body       TEXT;
    DECLARE v_body_type  VARCHAR(50);
    DECLARE v_model_hint VARCHAR(100);
    DECLARE v_claimed    INT DEFAULT 0;
    DECLARE v_done       INT DEFAULT 0;
    DECLARE v_attempts   INT DEFAULT 0;
    DECLARE v_max_attempts INT DEFAULT 50;

    -- Fast path: check if program is complete (all cells frozen)
    IF NOT EXISTS (
        SELECT 1 FROM cells
        WHERE program_id = p_program_id
          AND state NOT IN ('frozen', 'bottom')
    ) THEN
        SELECT 'complete'  AS action,
               NULL        AS cell_id,
               NULL        AS cell_name,
               NULL        AS body,
               NULL        AS body_type,
               NULL        AS model_hint,
               NULL        AS resolved_inputs;
        -- LEAVE not available outside a labeled block at top level;
        -- use IF/ELSE to avoid fall-through
    ELSE
        -- Try to claim a ready cell using INSERT IGNORE loop.
        -- Each iteration picks the first unclaimed ready cell and attempts
        -- an atomic INSERT. If another piston claimed it between our SELECT
        -- and INSERT, ROW_COUNT() = 0 and we retry with the next cell.
        --
        -- The NOT IN (SELECT cell_id FROM cell_claims) filter ensures we
        -- skip already-claimed cells, converging quickly even under contention.
        claim_block: BEGIN
            WHILE v_claimed = 0 AND v_attempts < v_max_attempts DO
                SET v_attempts = v_attempts + 1;
                SET v_cell_id = NULL;

                -- Find first unclaimed ready cell
                SELECT rc.id, rc.name, rc.body, rc.body_type, rc.model_hint
                  INTO v_cell_id, v_cell_name, v_body, v_body_type, v_model_hint
                  FROM ready_cells rc
                 WHERE rc.program_id = p_program_id
                   AND rc.id NOT IN (SELECT cell_id FROM cell_claims)
                 LIMIT 1;

                -- No unclaimed ready cells left
                IF v_cell_id IS NULL THEN
                    LEAVE claim_block;
                END IF;

                -- Atomic claim attempt: INSERT IGNORE silently fails on
                -- duplicate PRIMARY KEY (another piston already claimed it)
                INSERT IGNORE INTO cell_claims (cell_id, piston_id, claimed_at)
                VALUES (v_cell_id, p_piston_id, NOW());

                -- ROW_COUNT() = 1 means we won the claim
                IF ROW_COUNT() = 1 THEN
                    SET v_claimed = 1;
                END IF;

                -- ROW_COUNT() = 0 means another piston got it; loop will
                -- retry and the NOT IN filter will skip this cell
            END WHILE;
        END claim_block;

        IF v_claimed = 0 THEN
            -- No ready cells available (all claimed or truly none ready)
            SELECT 'quiescent' AS action,
                   NULL        AS cell_id,
                   NULL        AS cell_name,
                   NULL        AS body,
                   NULL        AS body_type,
                   NULL        AS model_hint,
                   NULL        AS resolved_inputs;
        ELSE
            -- Transition cell state: declared -> computing
            UPDATE cells
               SET state = 'computing'
             WHERE id = v_cell_id;

            -- Return dispatch info with resolved input values.
            -- Resolved inputs are a JSON object mapping "source_cell.field" to
            -- the frozen yield value, giving the piston everything it needs.
            SELECT 'dispatch'    AS action,
                   v_cell_id     AS cell_id,
                   v_cell_name   AS cell_name,
                   v_body        AS body,
                   v_body_type   AS body_type,
                   v_model_hint  AS model_hint,
                   (
                       SELECT JSON_OBJECTAGG(
                           CONCAT(g.source_cell, '.', g.source_field),
                           COALESCE(y.value_text, y.value_json)
                       )
                         FROM givens g
                         JOIN cells src
                           ON src.name = g.source_cell
                          AND src.program_id = p_program_id
                         JOIN yields y
                           ON y.cell_id = src.id
                          AND y.field_name = g.source_field
                          AND y.is_frozen = 1
                        WHERE g.cell_id = v_cell_id
                   ) AS resolved_inputs;
        END IF;
    END IF;
END //

DELIMITER ;
