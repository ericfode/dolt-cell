-- code-review: Manual pour SQL
-- Three cells: source (hard/literal), analyze (soft), summary (soft)

USE retort;

INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('code-review-source', 'code-review', 'source', 'hard', 'literal:function add(a, b) { return a + b; }', 'declared');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-source-code', 'code-review-source', 'code');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-source-language', 'code-review-source', 'language');

INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('code-review-analyze', 'code-review', 'analyze', 'soft', 'Review «code» written in «language». List bugs, style issues, and improvements as a JSON array of objects with keys: severity, category, message.', 'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-analyze-code', 'code-review-analyze', 'source', 'code');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-analyze-language', 'code-review-analyze', 'source', 'language');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-analyze-findings', 'code-review-analyze', 'findings');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-analyze-1', 'code-review-analyze', 'semantic', 'findings is a valid JSON array', NULL);

INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('code-review-summary', 'code-review', 'summary', 'soft', 'Summarize the code review findings into a one-paragraph report.', 'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-summary-findings', 'code-review-summary', 'analyze', 'findings');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-summary-report', 'code-review-summary', 'report');

CALL DOLT_COMMIT('-Am', 'pour: code-review');
