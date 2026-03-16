-- Retort: Cell Runtime Database Initialization
--
-- Consolidated schema from:
--   poc/schema.sql (core tables + views)
--   schema/cell_claims.sql (atomic claiming)
--   schema/cell_heartbeat.sql (heartbeat/lease, pistons)
--
-- Usage:
--   dolt sql --host 127.0.0.1 --port 3307 --user root \
--     -q "SOURCE schema/retort-init.sql;"
--
-- Bead: do-hrm

CREATE DATABASE IF NOT EXISTS retort;
USE retort;

-- ---------------------------------------------------------------------------
-- 1. Core tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS cells (
    id              VARCHAR(64) PRIMARY KEY,
    program_id      VARCHAR(64) NOT NULL,
    name            VARCHAR(128) NOT NULL,
    body_type       VARCHAR(8) NOT NULL DEFAULT 'soft',
    body            TEXT,
    state           VARCHAR(16) NOT NULL DEFAULT 'declared',
    model_hint      VARCHAR(32),
    claimed_by      VARCHAR(64),
    claimed_at      DATETIME,
    computing_since DATETIME DEFAULT NULL
        COMMENT 'Timestamp when this cell entered computing state. NULL when not computing.',
    assigned_piston VARCHAR(255) DEFAULT NULL
        COMMENT 'Identifier of the piston that claimed this cell. NULL when not computing.',
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_program_state (program_id, state),
    UNIQUE INDEX idx_cells_prog_name (program_id, name),
    INDEX idx_cells_computing_since (state, computing_since)
        COMMENT 'Supports cell_reap_stale() scanning for timed-out computing cells'
);

CREATE TABLE IF NOT EXISTS givens (
    id              VARCHAR(64) PRIMARY KEY,
    cell_id         VARCHAR(64) NOT NULL,
    source_cell     VARCHAR(64) NOT NULL COMMENT 'name of the source cell',
    source_field    VARCHAR(64) NOT NULL COMMENT 'field name on source cell',
    alias           VARCHAR(64) COMMENT 'local alias for this given',
    is_optional     BOOLEAN NOT NULL DEFAULT FALSE,
    guard_expr      VARCHAR(1024),
    FOREIGN KEY (cell_id) REFERENCES cells(id),
    INDEX idx_cell (cell_id),
    INDEX idx_source (source_cell)
);

CREATE TABLE IF NOT EXISTS yields (
    id          VARCHAR(64) PRIMARY KEY,
    cell_id     VARCHAR(64) NOT NULL,
    field_name  VARCHAR(64) NOT NULL,
    value_text  VARCHAR(4096),
    value_json  JSON,
    is_frozen   BOOLEAN NOT NULL DEFAULT FALSE,
    is_bottom   BOOLEAN NOT NULL DEFAULT FALSE,
    frozen_at   DATETIME,
    FOREIGN KEY (cell_id) REFERENCES cells(id),
    UNIQUE INDEX idx_cell_field (cell_id, field_name)
);

CREATE TABLE IF NOT EXISTS oracles (
    id              VARCHAR(64) PRIMARY KEY,
    cell_id         VARCHAR(64) NOT NULL,
    oracle_type     VARCHAR(16) NOT NULL,
    assertion       VARCHAR(1024) NOT NULL,
    condition_expr  VARCHAR(1024) COMMENT 'SQL expression for deterministic check',
    FOREIGN KEY (cell_id) REFERENCES cells(id),
    INDEX idx_cell (cell_id)
);

CREATE TABLE IF NOT EXISTS trace (
    id          VARCHAR(64) PRIMARY KEY,
    cell_id     VARCHAR(64) NOT NULL,
    event_type  VARCHAR(32) NOT NULL,
    detail      VARCHAR(1024),
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_cell (cell_id)
);

-- ---------------------------------------------------------------------------
-- 2. Multi-piston claiming table
-- ---------------------------------------------------------------------------

-- Atomic cell claiming: first piston to INSERT wins (PRIMARY KEY constraint).
-- Dolt has no SELECT FOR UPDATE, so this provides atomic claiming via INSERT.
CREATE TABLE IF NOT EXISTS cell_claims (
    cell_id    VARCHAR(255) NOT NULL,
    piston_id  VARCHAR(255) NOT NULL,
    claimed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (cell_id),
    INDEX idx_cell_claims_piston (piston_id),
    INDEX idx_cell_claims_time (claimed_at)
);

-- ---------------------------------------------------------------------------
-- 3. Pistons registry
-- ---------------------------------------------------------------------------

-- Tracks active LLM pistons. Pistons register on startup and update their
-- heartbeat periodically. Stale heartbeats indicate dead pistons.
CREATE TABLE IF NOT EXISTS pistons (
    id              VARCHAR(255) PRIMARY KEY
                    COMMENT 'Unique piston identifier (e.g., session ID or agent name)',
    program_id      VARCHAR(255) NOT NULL
                    COMMENT 'The program this piston is working on',
    model_hint      VARCHAR(64) DEFAULT NULL
                    COMMENT 'Model affinity filter (e.g., haiku, opus). NULL = any.',
    started_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                    COMMENT 'When this piston was spawned',
    last_heartbeat  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                    COMMENT 'Last time this piston reported alive',
    status          VARCHAR(16) NOT NULL DEFAULT 'active'
                    COMMENT 'active | draining | dead',
    cells_completed INT NOT NULL DEFAULT 0
                    COMMENT 'Count of cells this piston has successfully evaluated',
    INDEX idx_pistons_heartbeat (status, last_heartbeat)
        COMMENT 'Supports stale piston detection',
    INDEX idx_pistons_program (program_id, status)
        COMMENT 'Supports orphaned program detection'
);

-- ---------------------------------------------------------------------------
-- 4. Views
-- ---------------------------------------------------------------------------

-- ready_cells: cells whose ALL non-optional givens have frozen yields
-- NOTE: Uses NOT IN instead of NOT EXISTS — Dolt v1.83 has a correlated
-- subquery bug where NOT EXISTS with outer table refs returns wrong results.
CREATE OR REPLACE VIEW ready_cells AS
SELECT c.id, c.program_id, c.name, c.body_type, c.body, c.state, c.model_hint
FROM cells c
WHERE c.state = 'declared'
  AND c.id NOT IN (
    SELECT g.cell_id FROM givens g
    JOIN cells src ON src.program_id = c.program_id AND src.name = g.source_cell
    LEFT JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field AND y.is_frozen = 1
    WHERE g.is_optional = FALSE AND y.id IS NULL
  );

-- cell_program_status: overview of all cells in a program
CREATE OR REPLACE VIEW cell_program_status AS
SELECT
    c.program_id,
    c.name,
    c.state,
    c.body_type,
    c.claimed_by,
    GROUP_CONCAT(
        CONCAT(y.field_name, '=', COALESCE(
            CASE WHEN y.is_frozen THEN CONCAT('[FROZEN] ', LEFT(COALESCE(y.value_text, CAST(y.value_json AS CHAR)), 40))
                 ELSE '(pending)' END,
            '(no yield)')
        ) SEPARATOR '; '
    ) as yields_summary
FROM cells c
LEFT JOIN yields y ON y.cell_id = c.id
GROUP BY c.id, c.program_id, c.name, c.state, c.body_type, c.claimed_by;

-- ---------------------------------------------------------------------------
-- 5. Dolt configuration
-- ---------------------------------------------------------------------------

-- Exclude trace table from Dolt versioning (high-volume, append-only)
INSERT IGNORE INTO dolt_ignore VALUES ('trace', 1);
