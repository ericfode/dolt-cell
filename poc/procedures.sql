DELIMITER //
CREATE PROCEDURE cell_eval_step(IN p_program_id VARCHAR(64))
BEGIN
    DECLARE v_cell_id VARCHAR(64);
    DECLARE v_cell_name VARCHAR(128);
    DECLARE v_body_type VARCHAR(8);
    DECLARE v_body VARCHAR(4096);
    DECLARE v_model_hint VARCHAR(32);
    DECLARE v_literal_val VARCHAR(4096);

    SELECT id, name, body_type, body, model_hint
    INTO v_cell_id, v_cell_name, v_body_type, v_body, v_model_hint
    FROM ready_cells
    WHERE program_id = p_program_id
    LIMIT 1;

    IF v_cell_id IS NOT NULL THEN
        UPDATE cells SET
            state = 'computing',
            claimed_by = CONNECTION_ID(),
            claimed_at = NOW()
        WHERE id = v_cell_id AND state = 'declared';

        INSERT INTO trace (id, cell_id, event_type, detail, created_at)
        VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'claimed',
                CONCAT('Claimed by connection ', CONNECTION_ID()), NOW());
    END IF;

    IF v_cell_id IS NOT NULL AND v_body_type = 'hard' THEN
        IF v_body LIKE 'literal:%' THEN
            SET v_literal_val = SUBSTRING(v_body, 9);

            DELETE FROM yields WHERE cell_id = v_cell_id AND field_name = 'value';
            INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at)
            VALUES (CONCAT('y-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'value', v_literal_val, TRUE, NOW());

            UPDATE cells SET state = 'frozen' WHERE id = v_cell_id;

            INSERT INTO trace (id, cell_id, event_type, detail, created_at)
            VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'frozen',
                    'Hard cell evaluated and frozen', NOW());

            CALL DOLT_COMMIT('-Am', CONCAT('cell: freeze hard cell ', v_cell_name));
        END IF;

        SELECT
            'evaluated' as action,
            v_cell_name as cell_name,
            v_body_type as body_type,
            NULL as prompt,
            v_model_hint as model_hint;

    ELSEIF v_cell_id IS NOT NULL AND v_body_type = 'soft' THEN
        CALL DOLT_COMMIT('-Am', CONCAT('cell: claim soft cell ', v_cell_name));

        -- Return dispatch with simple prompt (Dolt has issues with subqueries in SELECT output)
        SELECT
            'dispatch' as action,
            v_cell_name as cell_name,
            v_body_type as body_type,
            CONCAT('## Cell: ', v_cell_name, '\n\n### Instructions:\n', v_body) as prompt,
            v_model_hint as model_hint;
    ELSE
        SELECT
            'quiescent' as action,
            NULL as cell_name,
            NULL as body_type,
            NULL as prompt,
            NULL as model_hint;
    END IF;
END //

CREATE PROCEDURE cell_submit(
    IN p_program_id VARCHAR(64),
    IN p_cell_name VARCHAR(128),
    IN p_field_name VARCHAR(64),
    IN p_value VARCHAR(4096)
)
BEGIN
    DECLARE v_cell_id VARCHAR(64);
    DECLARE v_oracle_count INT DEFAULT 0;
    DECLARE v_oracle_pass INT DEFAULT 0;
    DECLARE v_all_yields_frozen BOOLEAN DEFAULT FALSE;

    SELECT id INTO v_cell_id
    FROM cells
    WHERE program_id = p_program_id AND name = p_cell_name AND state = 'computing';

    IF v_cell_id IS NULL THEN
        SELECT 'error' as result, CONCAT('Cell "', p_cell_name, '" not found or not in computing state') as message;
    ELSE
        DELETE FROM yields WHERE cell_id = v_cell_id AND field_name = p_field_name;
        INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at)
        VALUES (CONCAT('y-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, p_field_name, p_value, FALSE, NULL);

        SELECT COUNT(*) INTO v_oracle_count
        FROM oracles WHERE cell_id = v_cell_id AND oracle_type = 'deterministic';

        IF v_oracle_count > 0 THEN
            -- Check simple oracles (no JSON parsing)
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

                SELECT 'oracle_fail' as result,
                       CONCAT(v_oracle_pass, '/', v_oracle_count, ' oracles passed') as message,
                       p_field_name as field_name;
            ELSE
                UPDATE yields SET is_frozen = TRUE, frozen_at = NOW()
                WHERE cell_id = v_cell_id AND field_name = p_field_name;

                SELECT NOT EXISTS(
                    SELECT 1 FROM yields WHERE cell_id = v_cell_id AND is_frozen = FALSE
                ) INTO v_all_yields_frozen;

                IF v_all_yields_frozen THEN
                    UPDATE cells SET state = 'frozen' WHERE id = v_cell_id;

                    INSERT INTO trace (id, cell_id, event_type, detail, created_at)
                    VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'frozen',
                            CONCAT('All yields frozen, cell complete'), NOW());

                    CALL DOLT_COMMIT('-Am', CONCAT('cell: freeze ', p_cell_name, '.', p_field_name));
                END IF;

                SELECT 'ok' as result,
                       CONCAT('Yield frozen: ', p_cell_name, '.', p_field_name) as message,
                       p_field_name as field_name;
            END IF;
        ELSE
            UPDATE yields SET is_frozen = TRUE, frozen_at = NOW()
            WHERE cell_id = v_cell_id AND field_name = p_field_name;

            SELECT NOT EXISTS(
                SELECT 1 FROM yields WHERE cell_id = v_cell_id AND is_frozen = FALSE
            ) INTO v_all_yields_frozen;

            IF v_all_yields_frozen THEN
                UPDATE cells SET state = 'frozen' WHERE id = v_cell_id;

                INSERT INTO trace (id, cell_id, event_type, detail, created_at)
                VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'frozen',
                        'Cell frozen (no oracles)', NOW());

                CALL DOLT_COMMIT('-Am', CONCAT('cell: freeze ', p_cell_name, '.', p_field_name));
            END IF;

            SELECT 'ok' as result,
                   CONCAT('Yield frozen: ', p_cell_name, '.', p_field_name) as message,
                   p_field_name as field_name;
        END IF;
    END IF;
END //

CREATE PROCEDURE cell_status(IN p_program_id VARCHAR(64))
BEGIN
    SELECT
        c.name,
        c.state,
        c.body_type,
        c.claimed_by,
        y.field_name,
        CASE
            WHEN y.is_frozen THEN CONCAT('[FROZEN] ', LEFT(COALESCE(y.value_text, ''), 60))
            WHEN y.value_text IS NOT NULL THEN CONCAT('[TENTATIVE] ', LEFT(y.value_text, 60))
            ELSE '(no yield)'
        END as yield_status,
        y.is_frozen
    FROM cells c
    LEFT JOIN yields y ON y.cell_id = c.id
    WHERE c.program_id = p_program_id
    ORDER BY
        FIELD(c.state, 'frozen', 'computing', 'ready', 'declared'),
        c.name;
END //
DELIMITER ;
