-- cell_claims: Atomic frame-level claiming for multi-piston execution
--
-- Matches formal claimMutex (I6): at most one claim per frame.
-- Formal claimValid requires: frame exists, is ready, and not already claimed.
-- See Claims.lean claimStep: `if s.holder fid |>.isNone then ...`
--
-- Dolt has no SELECT FOR UPDATE (row-level locking). This table provides
-- atomic claiming via INSERT: first piston to INSERT wins (UNIQUE constraint
-- on frame_id), others get duplicate key error and try the next ready cell.
--
-- Lifecycle:
--   1. replEvalStep() resolves frame, checks claimValid, INSERTs claim
--   2. replSubmit() DELETEs the claim after successful freeze
--   3. replRelease() DELETEs the claim on failure/timeout
--
-- For stuck pistons (crash, timeout), see do-6lq (heartbeat/lease system).
-- Until that's built, stale claims can be cleaned up by:
--   DELETE FROM cell_claims WHERE claimed_at < NOW() - INTERVAL 30 MINUTE;
--
-- Bead: do-i5p, do-7i1.37

CREATE TABLE IF NOT EXISTS cell_claims (
    cell_id   VARCHAR(255) NOT NULL,
    frame_id  VARCHAR(64) NOT NULL COMMENT 'Frame being claimed (formal: ClaimData.frameId)',
    piston_id VARCHAR(255) NOT NULL,
    claimed_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (cell_id),
    UNIQUE INDEX idx_cell_claims_frame (frame_id),
    INDEX idx_cell_claims_piston (piston_id),
    INDEX idx_cell_claims_time (claimed_at)
);
