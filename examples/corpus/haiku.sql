-- haiku: Manual pour SQL
-- Two cells: topic (hard/literal), compose (soft with 2 oracles)

USE retort;

INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('haiku-topic', 'haiku', 'topic', 'hard', 'literal:autumn leaves', 'declared');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-topic-subject', 'haiku-topic', 'subject');

INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('haiku-compose', 'haiku', 'compose', 'soft', 'Write a haiku about «subject».', 'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-compose-subject', 'haiku-compose', 'topic', 'subject');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-compose-poem', 'haiku-compose', 'poem');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-compose-1', 'haiku-compose', 'semantic', 'poem has exactly three lines', NULL);

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-compose-2', 'haiku-compose', 'semantic', 'poem follows 5-7-5 syllable pattern', NULL);

CALL DOLT_COMMIT('-Am', 'pour: haiku');
