-- Cell Runtime: Production Stored Procedures
--
-- Consolidated from:
--   - poc/procedures.sql (cell_eval_step, cell_submit, cell_status)
--   - schema/cell_eval_step.sql (INSERT IGNORE claiming pattern)
--   - schema/cell_release_claim.sql (cell_release_claim, cell_expire_stale_claims)
--   - schema/cell_heartbeat.sql (cell_reap_stale, piston_*)
--
-- Key changes from PoC to production:
--   - cell_eval_step: INSERT IGNORE into cell_claims for atomic multi-piston claiming
--   - cell_eval_step: computing_since/assigned_piston tracking on cells
--   - cell_submit: claim cleanup (DELETE FROM cell_claims) on freeze
--   - cell_submit: piston cells_completed increment on freeze
--   - cell_reap_stale: integrated claim cleanup for stuck cells
--   - piston_deregister: integrated claim cleanup
--
-- Prerequisites:
--   - Retort database with tables: cells, givens, yields, oracles, trace,
--     cell_claims, pistons
--   - Views: ready_cells, cell_program_status
--
-- DOLT WORKAROUNDS (v1.83): Multiple stored procedure variable bugs:
--   1. DECLARE/param vars in UPDATE SET → Dolt treats as column names → use @session vars
--   2. SELECT TEXT INTO DECLARE var → returns internal pointer garbage → use LEFT(col, N)
--   3. CAST(TEXT AS CHAR) → returns NULL → use LEFT() instead
--   4. Session vars (@_*) in SELECT INTO → "variable not found" → use DECLARE vars
-- Strategy: DECLARE for SELECT INTO / INSERT / WHERE; session vars for UPDATE SET.
--
-- The REPL (ct repl) uses Go-native SQL instead of calling these procedures,
-- which is the preferred approach. These procedures exist for the piston
-- system prompt (LLM pistons call them via dolt sql).
--
-- Installation: Cannot use `dolt sql < procedures.sql` (DELIMITER not supported).
-- Use a MySQL client or the Go installer: `go run tools/install-procedures.go`
--
-- Bead: do-ylj

-- ============================================================================
-- 1. cell_eval_step — Claim a ready cell and return dispatch info
-- ============================================================================
--
-- Finds the next ready cell in a program, atomically claims it via INSERT
-- IGNORE into cell_claims (first piston wins), and returns dispatch info.
--
-- Hard cells are evaluated inline:
--   body LIKE 'literal:%' → literal value written as frozen yield
--   body LIKE 'sql:%'     → SQL query executed via prepared statement, result frozen
--
-- Soft cells are marked 'computing' and returned with resolved input values
-- so the piston can evaluate them.
--
-- Returns:
--   action          - 'dispatch' | 'evaluated' | 'quiescent' | 'complete'
--   cell_id         - The claimed cell's ID
--   cell_name       - The cell's human-readable name
--   body            - Cell body (prompt for soft, literal: prefix for hard)
--   body_type       - 'soft' | 'hard'
--   model_hint      - Preferred model for soft cells
--   resolved_inputs - JSON object of resolved given values (soft cells only)

DELIMITER //

DROP PROCEDURE IF EXISTS cell_eval_step //

CREATE PROCEDURE cell_eval_step(
    IN p_program_id VARCHAR(255),
    IN p_piston_id  VARCHAR(255)
)
BEGIN
    -- DOLT WORKAROUND (v1.83): Variables (DECLARE or params) break in
    -- UPDATE SET contexts — Dolt treats them as column names.
    -- DECLARE vars DO work in SELECT INTO and INSERT VALUES.
    -- Session vars break in SELECT INTO but work in UPDATE SET.
    -- Strategy: DECLARE for SELECT INTO / INSERT / WHERE / control flow,
    -- session vars (@_es_*) for UPDATE SET values only.
    DECLARE v_cell_id    VARCHAR(255) DEFAULT NULL;
    DECLARE v_cell_name  VARCHAR(255);
    DECLARE v_body       TEXT;
    DECLARE v_body_type  VARCHAR(50);
    DECLARE v_model_hint VARCHAR(100);
    DECLARE v_claimed    INT DEFAULT 0;
    DECLARE v_attempts   INT DEFAULT 0;


    -- Fast path: check if program is complete (all non-stem cells frozen or bottom)
    IF NOT EXISTS (
        SELECT 1 FROM cells
        WHERE program_id = p_program_id
          AND body_type != 'stem'
          AND state NOT IN ('frozen', 'bottom')
    ) THEN
        SELECT 'complete'  AS action,
               NULL        AS cell_id,
               NULL        AS cell_name,
               NULL        AS body,
               NULL        AS body_type,
               NULL        AS model_hint,
               NULL        AS resolved_inputs;
    ELSE
        -- Claim loop: INSERT IGNORE into cell_claims, first piston wins.
        claim_block: BEGIN
            WHILE v_claimed = 0 AND v_attempts < 50 DO
                SET v_attempts = v_attempts + 1;
                SET v_cell_id = NULL;

                -- LEFT() works around Dolt bug: SELECT TEXT INTO returns
                -- internal pointer garbage. CAST also fails. LEFT materializes.
                SELECT rc.id, rc.name, LEFT(rc.body, 4096), rc.body_type, rc.model_hint
                  INTO v_cell_id, v_cell_name, v_body, v_body_type, v_model_hint
                  FROM ready_cells rc
                 WHERE rc.program_id = p_program_id
                   AND rc.id NOT IN (SELECT cell_id FROM cell_claims)
                 LIMIT 1;

                IF v_cell_id IS NULL THEN
                    LEAVE claim_block;
                END IF;

                INSERT IGNORE INTO cell_claims (cell_id, piston_id, claimed_at)
                VALUES (v_cell_id, p_piston_id, NOW());

                IF ROW_COUNT() = 1 THEN
                    SET v_claimed = 1;
                END IF;
            END WHILE;
        END claim_block;

        IF v_claimed = 0 THEN
            SELECT 'quiescent' AS action,
                   NULL        AS cell_id,
                   NULL        AS cell_name,
                   NULL        AS body,
                   NULL        AS body_type,
                   NULL        AS model_hint,
                   NULL        AS resolved_inputs;

        ELSEIF v_body_type = 'hard' THEN
            -- Hard cell: evaluate inline
            -- UPDATE SET needs session vars (Dolt workaround)
            SET @_es_piston_id = p_piston_id;
            UPDATE cells
               SET state = 'computing',
                   computing_since = NOW(),
                   assigned_piston = @_es_piston_id
             WHERE id = v_cell_id;

            IF v_body LIKE 'literal:%' THEN
                SET @_es_body = v_body;
                SET @_es_literal_val = SUBSTRING(@_es_body, 9);

                UPDATE yields
                   SET value_text = @_es_literal_val,
                       is_frozen = TRUE,
                       frozen_at = NOW()
                 WHERE cell_id = v_cell_id
                   AND is_frozen = FALSE;

                UPDATE cells
                   SET state = 'frozen',
                       computing_since = NULL,
                       assigned_piston = NULL
                 WHERE id = v_cell_id;

                DELETE FROM cell_claims WHERE cell_id = v_cell_id;

                -- claim_log: record completion (formal: claims.filter on freeze)
                SET @_cl_frame_id = NULL;
                SELECT id INTO @_cl_frame_id FROM frames
                 WHERE program_id = p_program_id AND cell_name = v_cell_name
                 ORDER BY generation DESC LIMIT 1;
                IF @_cl_frame_id IS NOT NULL THEN
                    INSERT IGNORE INTO claim_log (id, frame_id, piston_id, action)
                    VALUES (CONCAT('cl-', SUBSTR(MD5(RAND()), 1, 8)), @_cl_frame_id, @_es_piston_id, 'completed');
                END IF;

                UPDATE pistons
                   SET cells_completed = cells_completed + 1,
                       last_heartbeat = NOW()
                 WHERE id = @_es_piston_id;

                INSERT INTO trace (id, cell_id, event_type, detail, created_at)
                VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'frozen',
                        'Hard cell evaluated: literal value', NOW());

                CALL DOLT_COMMIT('-Am', CONCAT('cell: freeze hard cell ', v_cell_name));

            ELSEIF v_body LIKE 'sql:%' THEN
                -- Execute SQL query via prepared statement, capture scalar result.
                -- Must copy v_body to session var: Dolt can't resolve DECLARE vars
                -- in SET expressions that feed PREPARE.
                SET @_es_body = v_body;
                SET @_eval_sql = CONCAT('SELECT (', TRIM(SUBSTRING(@_es_body, 5)), ') INTO @_eval_result');
                PREPARE _eval_stmt FROM @_eval_sql;
                EXECUTE _eval_stmt;
                DEALLOCATE PREPARE _eval_stmt;

                -- UPDATE SET needs session var (Dolt workaround)
                UPDATE yields
                   SET value_text = @_eval_result,
                       is_frozen = TRUE,
                       frozen_at = NOW()
                 WHERE cell_id = v_cell_id
                   AND is_frozen = FALSE;

                UPDATE cells
                   SET state = 'frozen',
                       computing_since = NULL,
                       assigned_piston = NULL
                 WHERE id = v_cell_id;

                DELETE FROM cell_claims WHERE cell_id = v_cell_id;

                -- claim_log: record completion (formal: claims.filter on freeze)
                SET @_cl_frame_id = NULL;
                SELECT id INTO @_cl_frame_id FROM frames
                 WHERE program_id = p_program_id AND cell_name = v_cell_name
                 ORDER BY generation DESC LIMIT 1;
                IF @_cl_frame_id IS NOT NULL THEN
                    INSERT IGNORE INTO claim_log (id, frame_id, piston_id, action)
                    VALUES (CONCAT('cl-', SUBSTR(MD5(RAND()), 1, 8)), @_cl_frame_id, @_es_piston_id, 'completed');
                END IF;

                UPDATE pistons
                   SET cells_completed = cells_completed + 1,
                       last_heartbeat = NOW()
                 WHERE id = @_es_piston_id;

                INSERT INTO trace (id, cell_id, event_type, detail, created_at)
                VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'frozen',
                        'Hard cell evaluated: sql query', NOW());

                CALL DOLT_COMMIT('-Am', CONCAT('cell: freeze hard cell ', v_cell_name));
            END IF;

            SELECT 'evaluated'   AS action,
                   v_cell_id     AS cell_id,
                   v_cell_name   AS cell_name,
                   v_body        AS body,
                   v_body_type   AS body_type,
                   v_model_hint  AS model_hint,
                   NULL          AS resolved_inputs;

        ELSE
            -- Soft cell: mark computing and dispatch to piston
            SET @_es_piston_id = p_piston_id;
            -- DOLT WORKAROUND (v1.83): p_program_id can't be resolved inside
            -- correlated subqueries in SELECT. Copy to session var first.
            SET @_es_program_id = p_program_id;
            UPDATE cells
               SET state = 'computing',
                   computing_since = NOW(),
                   assigned_piston = @_es_piston_id
             WHERE id = v_cell_id;

            INSERT INTO trace (id, cell_id, event_type, detail, created_at)
            VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'claimed',
                    CONCAT('Claimed by piston ', p_piston_id), NOW());

            CALL DOLT_COMMIT('-Am', CONCAT('cell: claim soft cell ', v_cell_name));

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
                          AND src.program_id = @_es_program_id
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

-- ============================================================================
-- 2. cell_submit — Submit a yield value for a computing cell
-- ============================================================================
--
-- Called by the piston after evaluating a soft cell. Writes the yield value,
-- checks deterministic oracles, and freezes the cell if all yields are frozen.
--
-- On successful freeze:
--   - Deletes the cell_claims entry
--   - Increments the piston's cells_completed counter
--   - Clears computing_since/assigned_piston on the cell
--
-- Returns:
--   result     - 'ok' | 'oracle_fail' | 'error'
--   message    - Human-readable status
--   field_name - The field that was submitted

DELIMITER //

DROP PROCEDURE IF EXISTS cell_submit //

CREATE PROCEDURE cell_submit(
    IN p_program_id VARCHAR(255),
    IN p_cell_name  VARCHAR(255),
    IN p_field_name VARCHAR(64),
    IN p_value      TEXT
)
BEGIN
    DECLARE v_cell_id VARCHAR(255);
    DECLARE v_piston_id VARCHAR(255);
    DECLARE v_oracle_count INT DEFAULT 0;
    DECLARE v_oracle_pass INT DEFAULT 0;
    DECLARE v_all_yields_frozen BOOLEAN DEFAULT FALSE;

    SELECT id INTO v_cell_id
    FROM cells
    WHERE program_id = p_program_id AND name = p_cell_name AND state = 'computing';

    IF v_cell_id IS NULL THEN
        SELECT 'error' AS result,
               CONCAT('Cell "', p_cell_name, '" not found or not in computing state') AS message;
    ELSE
        -- Get piston ID from claim for stats update later
        SELECT piston_id INTO v_piston_id
        FROM cell_claims WHERE cell_id = v_cell_id;

        -- Write the yield value
        DELETE FROM yields WHERE cell_id = v_cell_id AND field_name = p_field_name;
        INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at)
        VALUES (CONCAT('y-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, p_field_name, p_value, FALSE, NULL);

        -- Check deterministic oracles
        SELECT COUNT(*) INTO v_oracle_count
        FROM oracles WHERE cell_id = v_cell_id AND oracle_type = 'deterministic';

        IF v_oracle_count > 0 THEN
            -- Check simple oracles (no JSON parsing needed)
            SELECT COUNT(*) INTO v_oracle_pass
            FROM oracles o
            WHERE o.cell_id = v_cell_id
              AND o.oracle_type = 'deterministic'
              AND (
                  (o.condition_expr = 'not_empty' AND p_value IS NOT NULL AND LENGTH(p_value) > 0)
                  OR
                  (o.condition_expr = 'is_json_array' AND p_value LIKE '[%]' AND p_value LIKE '%]')
              );

            -- Check JSON-based oracles only if value is valid JSON
            IF JSON_VALID(p_value) THEN
                SET v_oracle_pass = v_oracle_pass + (
                    SELECT COUNT(*)
                    FROM oracles o
                    WHERE o.cell_id = v_cell_id
                      AND o.oracle_type = 'deterministic'
                      AND o.condition_expr LIKE 'length_matches:%'
                      AND JSON_LENGTH(CAST(p_value AS JSON)) = JSON_LENGTH(
                          CAST((SELECT y2.value_text FROM yields y2
                                JOIN cells c2 ON c2.id = y2.cell_id
                                WHERE c2.program_id = p_program_id
                                  AND c2.name = SUBSTRING_INDEX(o.condition_expr, ':', -1)
                                  AND y2.field_name = 'value'
                                  AND y2.is_frozen = 1) AS JSON))
                );
            END IF;

            IF v_oracle_pass < v_oracle_count THEN
                INSERT INTO trace (id, cell_id, event_type, detail, created_at)
                VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'oracle_fail',
                        CONCAT('Oracle check failed: ', v_oracle_pass, '/', v_oracle_count, ' passed'), NOW());

                SELECT 'oracle_fail' AS result,
                       CONCAT(v_oracle_pass, '/', v_oracle_count, ' oracles passed') AS message,
                       p_field_name AS field_name;
            ELSE
                -- Oracle passed: freeze this yield
                UPDATE yields SET is_frozen = TRUE, frozen_at = NOW()
                WHERE cell_id = v_cell_id AND field_name = p_field_name;

                -- Check if all yields are now frozen
                SELECT NOT EXISTS(
                    SELECT 1 FROM yields WHERE cell_id = v_cell_id AND is_frozen = FALSE
                ) INTO v_all_yields_frozen;

                IF v_all_yields_frozen THEN
                    -- Freeze the cell
                    UPDATE cells
                       SET state = 'frozen',
                           computing_since = NULL,
                           assigned_piston = NULL
                     WHERE id = v_cell_id;

                    -- Clean up claim
                    DELETE FROM cell_claims WHERE cell_id = v_cell_id;

                    -- claim_log: record completion (formal: claims.filter on freeze)
                    SET @_cl_frame_id = NULL;
                    SELECT id INTO @_cl_frame_id FROM frames
                     WHERE program_id = p_program_id AND cell_name = p_cell_name
                     ORDER BY generation DESC LIMIT 1;
                    IF @_cl_frame_id IS NOT NULL AND v_piston_id IS NOT NULL THEN
                        INSERT IGNORE INTO claim_log (id, frame_id, piston_id, action)
                        VALUES (CONCAT('cl-', SUBSTR(MD5(RAND()), 1, 8)), @_cl_frame_id, v_piston_id, 'completed');
                    END IF;

                    -- Update piston stats
                    IF v_piston_id IS NOT NULL THEN
                        UPDATE pistons
                           SET cells_completed = cells_completed + 1,
                               last_heartbeat = NOW()
                         WHERE id = v_piston_id;
                    END IF;

                    INSERT INTO trace (id, cell_id, event_type, detail, created_at)
                    VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'frozen',
                            'All yields frozen, cell complete', NOW());

                    CALL DOLT_COMMIT('-Am', CONCAT('cell: freeze ', p_cell_name, '.', p_field_name));
                END IF;

                SELECT 'ok' AS result,
                       CONCAT('Yield frozen: ', p_cell_name, '.', p_field_name) AS message,
                       p_field_name AS field_name;
            END IF;
        ELSE
            -- No oracles: freeze yield directly
            UPDATE yields SET is_frozen = TRUE, frozen_at = NOW()
            WHERE cell_id = v_cell_id AND field_name = p_field_name;

            SELECT NOT EXISTS(
                SELECT 1 FROM yields WHERE cell_id = v_cell_id AND is_frozen = FALSE
            ) INTO v_all_yields_frozen;

            IF v_all_yields_frozen THEN
                UPDATE cells
                   SET state = 'frozen',
                       computing_since = NULL,
                       assigned_piston = NULL
                 WHERE id = v_cell_id;

                -- Clean up claim
                DELETE FROM cell_claims WHERE cell_id = v_cell_id;

                -- claim_log: record completion (formal: claims.filter on freeze)
                SET @_cl_frame_id = NULL;
                SELECT id INTO @_cl_frame_id FROM frames
                 WHERE program_id = p_program_id AND cell_name = p_cell_name
                 ORDER BY generation DESC LIMIT 1;
                IF @_cl_frame_id IS NOT NULL AND v_piston_id IS NOT NULL THEN
                    INSERT IGNORE INTO claim_log (id, frame_id, piston_id, action)
                    VALUES (CONCAT('cl-', SUBSTR(MD5(RAND()), 1, 8)), @_cl_frame_id, v_piston_id, 'completed');
                END IF;

                -- Update piston stats
                IF v_piston_id IS NOT NULL THEN
                    UPDATE pistons
                       SET cells_completed = cells_completed + 1,
                           last_heartbeat = NOW()
                     WHERE id = v_piston_id;
                END IF;

                INSERT INTO trace (id, cell_id, event_type, detail, created_at)
                VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'frozen',
                        'Cell frozen (no oracles)', NOW());

                CALL DOLT_COMMIT('-Am', CONCAT('cell: freeze ', p_cell_name, '.', p_field_name));
            END IF;

            SELECT 'ok' AS result,
                   CONCAT('Yield frozen: ', p_cell_name, '.', p_field_name) AS message,
                   p_field_name AS field_name;
        END IF;
    END IF;
END //

DELIMITER ;

-- ============================================================================
-- 3. cell_status — Show program cell and yield status
-- ============================================================================

DELIMITER //

DROP PROCEDURE IF EXISTS cell_status //

CREATE PROCEDURE cell_status(IN p_program_id VARCHAR(255))
BEGIN
    SELECT
        c.name,
        c.state,
        c.body_type,
        c.assigned_piston,
        y.field_name,
        CASE
            WHEN y.is_frozen THEN CONCAT('[FROZEN] ', LEFT(COALESCE(y.value_text, ''), 60))
            WHEN y.value_text IS NOT NULL THEN CONCAT('[TENTATIVE] ', LEFT(y.value_text, 60))
            ELSE '(no yield)'
        END AS yield_status,
        y.is_frozen
    FROM cells c
    LEFT JOIN yields y ON y.cell_id = c.id
    WHERE c.program_id = p_program_id
    ORDER BY
        FIELD(c.state, 'frozen', 'computing', 'ready', 'declared'),
        c.name;
END //

DELIMITER ;

-- ============================================================================
-- 4. cell_release_claim — Release a piston's claim on a cell
-- ============================================================================
--
-- Called on evaluation failure/timeout to return a cell to the ready pool.
-- On 'success': just deletes the claim (cell already frozen by cell_submit).
-- On 'failure'/'timeout': deletes claim AND resets cell to 'declared'.
--
-- Safety: only the owning piston can release its own claim.

DELIMITER //

DROP PROCEDURE IF EXISTS cell_release_claim //

CREATE PROCEDURE cell_release_claim(
    IN p_cell_id   VARCHAR(255),
    IN p_piston_id VARCHAR(255),
    IN p_reason    VARCHAR(20)
)
BEGIN
    DECLARE v_rows_affected INT DEFAULT 0;

    -- claim_log: record release/timeout (formal: claims.filter on release)
    SET @_cl_frame_id = NULL;
    SET @_cl_cell_name = NULL;
    SET @_cl_prog_id = NULL;
    SELECT name, program_id INTO @_cl_cell_name, @_cl_prog_id
      FROM cells WHERE id = p_cell_id;
    IF @_cl_prog_id IS NOT NULL THEN
        SELECT id INTO @_cl_frame_id FROM frames
         WHERE program_id = @_cl_prog_id AND cell_name = @_cl_cell_name
         ORDER BY generation DESC LIMIT 1;
    END IF;

    DELETE FROM cell_claims
     WHERE cell_id = p_cell_id
       AND piston_id = p_piston_id;

    SET v_rows_affected = ROW_COUNT();

    IF v_rows_affected = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'No matching claim found for this piston';
    END IF;

    IF v_rows_affected > 0 AND @_cl_frame_id IS NOT NULL THEN
        INSERT IGNORE INTO claim_log (id, frame_id, piston_id, action)
        VALUES (CONCAT('cl-', SUBSTR(MD5(RAND()), 1, 8)), @_cl_frame_id, p_piston_id,
                CASE WHEN p_reason = 'timeout' THEN 'timed_out' ELSE 'released' END);
    END IF;

    IF p_reason IN ('failure', 'timeout') THEN
        UPDATE cells
           SET state = 'declared',
               computing_since = NULL,
               assigned_piston = NULL
         WHERE id = p_cell_id
           AND state = 'computing';
    END IF;
END //

DELIMITER ;

-- ============================================================================
-- 5. cell_expire_stale_claims — Clean up claims from dead pistons
-- ============================================================================
--
-- Finds claims older than the given threshold, resets their cells to
-- 'declared', and removes the stale claims.

DELIMITER //

DROP PROCEDURE IF EXISTS cell_expire_stale_claims //

CREATE PROCEDURE cell_expire_stale_claims(
    IN p_max_age_minutes INT
)
BEGIN
    IF p_max_age_minutes IS NULL OR p_max_age_minutes <= 0 THEN
        SET p_max_age_minutes = 30;
    END IF;

    -- Reset cells that were claimed by dead pistons
    UPDATE cells c
      JOIN cell_claims cc ON cc.cell_id = c.id
       SET c.state = 'declared',
           c.computing_since = NULL,
           c.assigned_piston = NULL
     WHERE cc.claimed_at < NOW() - INTERVAL p_max_age_minutes MINUTE
       AND c.state = 'computing';

    -- claim_log: record timed_out for stale claims (formal: claims.filter on release)
    INSERT IGNORE INTO claim_log (id, frame_id, piston_id, action)
    SELECT CONCAT('cl-', SUBSTR(MD5(RAND()), 1, 8)), f.id, cc.piston_id, 'timed_out'
      FROM cell_claims cc
      JOIN cells c ON c.id = cc.cell_id
      JOIN frames f ON f.program_id = c.program_id AND f.cell_name = c.name
     WHERE cc.claimed_at < NOW() - INTERVAL p_max_age_minutes MINUTE
       AND f.generation = (
           SELECT MAX(f2.generation) FROM frames f2
            WHERE f2.program_id = c.program_id AND f2.cell_name = c.name
       );

    -- Remove the stale claims
    DELETE FROM cell_claims
     WHERE claimed_at < NOW() - INTERVAL p_max_age_minutes MINUTE;
END //

DELIMITER ;

-- ============================================================================
-- 6. cell_reap_stale — Reset stuck computing cells (heartbeat-based)
-- ============================================================================
--
-- Comprehensive recovery procedure:
--   1. Marks stale pistons as dead
--   2. Clears tentative yields from stuck cells
--   3. Logs recovery to trace
--   4. Cleans up orphaned claims
--   5. Resets stuck cells to 'declared'
--   6. Detects orphaned programs (work but no active pistons)
--
-- Does NOT increment retry_count — piston death is infrastructure failure,
-- not evaluation failure.

DELIMITER //

DROP PROCEDURE IF EXISTS cell_reap_stale //

CREATE PROCEDURE cell_reap_stale(IN timeout_minutes INT)
BEGIN
    DECLARE v_reaped INT DEFAULT 0;
    DECLARE v_cleared INT DEFAULT 0;
    DECLARE v_stale_pistons INT DEFAULT 0;
    DECLARE v_orphaned TEXT DEFAULT '';
    DECLARE v_now DATETIME;

    SET v_now = NOW();

    IF timeout_minutes IS NULL OR timeout_minutes <= 0 THEN
        SET timeout_minutes = 10;
    END IF;

    -- Step 1: Mark stale pistons as dead
    UPDATE pistons
    SET status = 'dead'
    WHERE status = 'active'
      AND last_heartbeat < v_now - INTERVAL timeout_minutes MINUTE;

    SET v_stale_pistons = ROW_COUNT();

    -- Step 2: Clear tentative yields from stuck cells
    UPDATE yields y
    INNER JOIN cells c ON y.cell_id = c.id
    SET y.value_text = NULL, y.value_json = NULL
    WHERE c.state = 'computing'
      AND c.computing_since < v_now - INTERVAL timeout_minutes MINUTE
      AND y.is_frozen = 0
      AND y.value_text IS NOT NULL;

    SET v_cleared = ROW_COUNT();

    -- Step 3: Log recovery to trace
    INSERT INTO trace (id, cell_id, event_type, detail, created_at)
    SELECT
        CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)),
        c.id,
        'reap_stale',
        CONCAT('Piston timeout: ', COALESCE(c.assigned_piston, 'unknown'),
               ' computing_since=', COALESCE(CAST(c.computing_since AS CHAR), 'null'),
               ' timeout=', timeout_minutes, 'min'),
        v_now
    FROM cells c
    WHERE c.state = 'computing'
      AND c.computing_since < v_now - INTERVAL timeout_minutes MINUTE;

    -- Step 4: Clean up claims for stuck cells
    DELETE cc FROM cell_claims cc
    INNER JOIN cells c ON cc.cell_id = c.id
    WHERE c.state = 'computing'
      AND c.computing_since < v_now - INTERVAL timeout_minutes MINUTE;

    -- Step 5: Reset stuck cells back to declared
    UPDATE cells
    SET state = 'declared',
        computing_since = NULL,
        assigned_piston = NULL
    WHERE state = 'computing'
      AND computing_since < v_now - INTERVAL timeout_minutes MINUTE;

    SET v_reaped = ROW_COUNT();

    -- Step 6: Detect orphaned programs (declared cells but no active pistons)
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

    SELECT
        v_reaped AS reaped_cells,
        v_cleared AS cleared_yields,
        v_orphaned AS orphaned_programs,
        v_stale_pistons AS stale_pistons;
END //

DELIMITER ;

-- ============================================================================
-- 7. piston_register — Register a new piston on startup
-- ============================================================================
--
-- Uses ON DUPLICATE KEY UPDATE so a restarted piston re-registers cleanly.

DELIMITER //

DROP PROCEDURE IF EXISTS piston_register //

CREATE PROCEDURE piston_register(
    IN p_id         VARCHAR(255),
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

-- ============================================================================
-- 8. piston_heartbeat — Update piston heartbeat timestamp
-- ============================================================================
--
-- Called periodically by each piston. Returns ROW_COUNT() = 0 if the piston
-- was already marked dead by the reaper, signaling re-registration needed.

DELIMITER //

DROP PROCEDURE IF EXISTS piston_heartbeat //

CREATE PROCEDURE piston_heartbeat(IN p_id VARCHAR(255))
BEGIN
    UPDATE pistons
    SET last_heartbeat = NOW()
    WHERE id = p_id AND status = 'active';

    SELECT ROW_COUNT() AS updated;
END //

DELIMITER ;

-- ============================================================================
-- 9. piston_deregister — Gracefully shut down a piston
-- ============================================================================
--
-- Releases any cells this piston had claimed and marks it dead.

DELIMITER //

DROP PROCEDURE IF EXISTS piston_deregister //

CREATE PROCEDURE piston_deregister(IN p_id VARCHAR(255))
BEGIN
    -- Release any cells this piston had claimed
    UPDATE cells
    SET state = 'declared',
        computing_since = NULL,
        assigned_piston = NULL
    WHERE assigned_piston = p_id
      AND state = 'computing';

    -- claim_log: record released for all piston claims (formal: claims.filter on release)
    INSERT IGNORE INTO claim_log (id, frame_id, piston_id, action)
    SELECT CONCAT('cl-', SUBSTR(MD5(RAND()), 1, 8)), f.id, cc.piston_id, 'released'
      FROM cell_claims cc
      JOIN cells c ON c.id = cc.cell_id
      JOIN frames f ON f.program_id = c.program_id AND f.cell_name = c.name
     WHERE cc.piston_id = p_id
       AND f.generation = (
           SELECT MAX(f2.generation) FROM frames f2
            WHERE f2.program_id = c.program_id AND f2.cell_name = c.name
       );

    -- Clean up claims
    DELETE FROM cell_claims WHERE piston_id = p_id;

    -- Mark piston dead
    UPDATE pistons
    SET status = 'dead'
    WHERE id = p_id;
END //

DELIMITER ;
