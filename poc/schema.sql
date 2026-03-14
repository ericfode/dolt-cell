-- Cell Runtime PoC: Schema (Retort-derived)

CREATE TABLE IF NOT EXISTS cells (
    id          VARCHAR(64) PRIMARY KEY,
    program_id  VARCHAR(64) NOT NULL,
    name        VARCHAR(128) NOT NULL,
    body_type   VARCHAR(8) NOT NULL DEFAULT 'soft',
    body        VARCHAR(4096),
    state       VARCHAR(16) NOT NULL DEFAULT 'declared',
    model_hint  VARCHAR(32),
    claimed_by  VARCHAR(64),
    claimed_at  DATETIME,
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_program_state (program_id, state),
    INDEX idx_name (program_id, name)
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

-- ready_cells: cells whose ALL non-optional givens have frozen yields
CREATE OR REPLACE VIEW ready_cells AS
SELECT c.id, c.program_id, c.name, c.body_type, c.body, c.state, c.model_hint
FROM cells c
WHERE c.state = 'declared'
  AND NOT EXISTS (
    SELECT 1 FROM givens g
    JOIN cells src ON src.program_id = c.program_id AND src.name = g.source_cell
    LEFT JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field AND y.is_frozen = 1
    WHERE g.cell_id = c.id
      AND g.is_optional = FALSE
      AND y.id IS NULL
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
