-- sort-proof: Manual pour SQL
-- Three cells: data (hard/literal), sort (soft), report (soft)
-- Data cell is pre-bound with a literal value.
-- Sort cell has two oracles: length_matches (deterministic) + ascending (semantic).

USE retort;

-- Cell: data (hard, literal pre-bound)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('sp-data', 'sort-proof', 'data', 'hard', 'literal:[4, 1, 7, 3, 9, 2]', 'declared');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-data-items', 'sp-data', 'items');

-- Cell: sort (soft, depends on data→items)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('sp-sort', 'sort-proof', 'sort', 'soft', 'Sort «items» in ascending order.', 'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-sort-items', 'sp-sort', 'data', 'items');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-sort-sorted', 'sp-sort', 'sorted');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-sort-1', 'sp-sort', 'deterministic', 'sorted is a permutation of items', 'length_matches:data');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-sort-2', 'sp-sort', 'semantic', 'sorted is in ascending order', NULL);

-- Cell: report (soft, depends on sort→sorted)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('sp-report', 'sort-proof', 'report', 'soft', 'Write a one-sentence summary of the sort result.', 'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-report-sorted', 'sp-report', 'sort', 'sorted');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-report-summary', 'sp-report', 'summary');

-- Commit the poured program into Dolt version history
CALL DOLT_COMMIT('-Am', 'pour: sort-proof');
