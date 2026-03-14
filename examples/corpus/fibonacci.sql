-- fibonacci: Manual pour SQL
-- Two cells: seed (hard/literal), compute (soft with 2 oracles)

USE retort;

INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('fibonacci-seed', 'fibonacci', 'seed', 'hard', 'literal:10', 'declared');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-seed-n', 'fibonacci-seed', 'n');

INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('fibonacci-compute', 'fibonacci', 'compute', 'soft', 'Generate the first «n» Fibonacci numbers as a JSON array.', 'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-compute-n', 'fibonacci-compute', 'seed', 'n');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-compute-sequence', 'fibonacci-compute', 'sequence');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-compute-1', 'fibonacci-compute', 'semantic', 'sequence is a valid JSON array', NULL);

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-compute-2', 'fibonacci-compute', 'semantic', 'sequence has exactly «n» elements', NULL);

CALL DOLT_COMMIT('-Am', 'pour: fibonacci');
