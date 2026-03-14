-- Pour SQL for code-review: Code Review
-- LLM analyzes code semantics (impossible in SQL), hard cell counts findings
USE retort;

-- Cell: source (hard, pre-bound literal)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('cr-source', 'code-review', 'source', 'hard',
        'literal:def is_prime(n): return all(n % i != 0 for i in range(2, n))',
        'declared');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-source-code', 'cr-source', 'code');

-- Cell: analyze (soft — LLM reviews the code for bugs and issues)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('cr-analyze', 'code-review', 'analyze', 'soft',
        'Review this Python function for correctness, performance, and style:\n\n«code»\n\nIdentify all bugs, edge cases, and potential improvements. Format each finding as a bullet point starting with \"- \".',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-analyze-code', 'cr-analyze', 'source', 'code');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-analyze-findings', 'cr-analyze', 'findings');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-analyze-1', 'cr-analyze', 'semantic',
        'findings contains at least 3 bullet points', NULL);

-- Cell: count-findings (hard — SQL counts bullet points in the findings)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('cr-count-findings', 'code-review', 'count-findings', 'hard',
        'sql:SELECT (LENGTH(f.value_text) - LENGTH(REPLACE(f.value_text, ''- '', ''''))) / 2 FROM yields f JOIN cells c ON f.cell_id = c.id WHERE c.name = ''analyze'' AND f.field_name = ''findings'' AND f.is_frozen = 1',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-count-findings', 'cr-count-findings', 'analyze', 'findings');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-count-total', 'cr-count-findings', 'total');

-- Cell: prioritize (soft — LLM classifies and ranks findings)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('cr-prioritize', 'code-review', 'prioritize', 'soft',
        'Given «total» findings from the code review:\n\n«findings»\n\nPrioritize these findings by severity (critical first, minor last). For each, classify as BUG, PERFORMANCE, or STYLE. Write a one-paragraph executive summary suitable for a pull request comment.',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-prioritize-findings', 'cr-prioritize', 'analyze', 'findings');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-prioritize-total', 'cr-prioritize', 'count-findings', 'total');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-prioritize-summary', 'cr-prioritize', 'summary');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-prioritize-1', 'cr-prioritize', 'deterministic',
        'summary is not empty', 'not_empty');

CALL DOLT_COMMIT('-Am', 'pour: code-review');
