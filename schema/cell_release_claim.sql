-- cell_release_claim: Release a piston's claim on a cell
--
-- Called by cell_submit() after successfully freezing a cell's yields,
-- or by the piston on evaluation failure/timeout to return the cell
-- to the ready pool.
--
-- Parameters:
--   p_cell_id    - The cell to release
--   p_piston_id  - The piston releasing the claim (must match claim owner)
--   p_reason     - 'success' | 'failure' | 'timeout'
--
-- On 'success': just delete the claim (cell is already frozen by cell_submit)
-- On 'failure': delete claim AND reset cell state to 'declared' for retry
-- On 'timeout': same as failure (cell returns to ready pool)
--
-- Safety: only the owning piston can release its own claim (piston_id check).
-- For expired claims from dead pistons, see cell_expire_stale_claims.
--
-- Bead: do-i5p

DELIMITER //

DROP PROCEDURE IF EXISTS cell_release_claim //

CREATE PROCEDURE cell_release_claim(
    IN p_cell_id   VARCHAR(255),
    IN p_piston_id VARCHAR(255),
    IN p_reason    VARCHAR(20)
)
BEGIN
    DECLARE v_rows_affected INT DEFAULT 0;

    -- Only delete if this piston owns the claim
    DELETE FROM cell_claims
     WHERE cell_id = p_cell_id
       AND piston_id = p_piston_id;

    SET v_rows_affected = ROW_COUNT();

    IF v_rows_affected = 0 THEN
        -- Claim doesn't exist or belongs to another piston
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'No matching claim found for this piston';
    END IF;

    -- On failure/timeout, return cell to declared state so it can be retried
    IF p_reason IN ('failure', 'timeout') THEN
        UPDATE cells
           SET state = 'declared'
         WHERE id = p_cell_id
           AND state = 'computing';
    END IF;
END //

DELIMITER ;


-- cell_expire_stale_claims: Clean up claims from dead pistons
--
-- Temporary solution until heartbeat/lease system (do-6lq) is built.
-- Finds claims older than the given threshold and releases them.
--
-- Parameters:
--   p_max_age_minutes - Claims older than this are expired (default: 30)

DROP PROCEDURE IF EXISTS cell_expire_stale_claims //

DELIMITER //

CREATE PROCEDURE cell_expire_stale_claims(
    IN p_max_age_minutes INT
)
BEGIN
    IF p_max_age_minutes IS NULL OR p_max_age_minutes <= 0 THEN
        SET p_max_age_minutes = 30;
    END IF;

    -- Reset cells that were claimed by dead pistons back to 'declared'
    UPDATE cells c
      JOIN cell_claims cc ON cc.cell_id = c.id
       SET c.state = 'declared'
     WHERE cc.claimed_at < NOW() - INTERVAL p_max_age_minutes MINUTE
       AND c.state = 'computing';

    -- Remove the stale claims
    DELETE FROM cell_claims
     WHERE claimed_at < NOW() - INTERVAL p_max_age_minutes MINUTE;
END //

DELIMITER ;
