-- cell_claims: Atomic cell claiming for multi-piston execution
--
-- Dolt has no SELECT FOR UPDATE (row-level locking). This table provides
-- atomic cell claiming via INSERT: first piston to INSERT wins (PRIMARY KEY
-- constraint), others get duplicate key error and try the next ready cell.
--
-- Lifecycle:
--   1. cell_eval_step() INSERTs a claim when dispatching a cell
--   2. cell_submit() DELETEs the claim after successful freeze
--   3. cell_release_claim() DELETEs the claim on failure/timeout
--
-- For stuck pistons (crash, timeout), see do-6lq (heartbeat/lease system).
-- Until that's built, stale claims can be cleaned up by:
--   DELETE FROM cell_claims WHERE claimed_at < NOW() - INTERVAL 30 MINUTE;
--
-- Bead: do-i5p

CREATE TABLE IF NOT EXISTS cell_claims (
    cell_id   VARCHAR(255) NOT NULL,
    piston_id VARCHAR(255) NOT NULL,
    claimed_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (cell_id),
    INDEX idx_cell_claims_piston (piston_id),
    INDEX idx_cell_claims_time (claimed_at)
);
