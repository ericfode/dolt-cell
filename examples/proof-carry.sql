-- Pour SQL for proof-carry: Proof-Carrying Computation
-- LLM factors an integer (NP), hard cell verifies by multiplication (P)
USE retort;

-- Cell: target (hard, pre-bound literal)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('pc-target', 'proof-carry', 'target', 'hard', 'literal:5963', 'declared');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-target-number', 'pc-target', 'number');

-- Cell: factor (soft — LLM must reason to find factors)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('pc-factor', 'proof-carry', 'factor', 'soft',
        'Find two non-trivial factors (both greater than 1) of the integer «number». Return as a JSON array of exactly two integers, e.g. [67, 89].',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-factor-number', 'pc-factor', 'target', 'number');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-factor-factors', 'pc-factor', 'factors');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-factor-1', 'pc-factor', 'deterministic',
        'factors is a valid JSON array', 'is_json_array');

-- Cell: verify-product (hard — SQL multiplies factors and checks against target)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('pc-verify-product', 'proof-carry', 'verify-product', 'hard',
        'sql:SELECT CASE WHEN CAST(JSON_EXTRACT(f.value_text, ''$[0]'') AS SIGNED) * CAST(JSON_EXTRACT(f.value_text, ''$[1]'') AS SIGNED) = CAST(n.value_text AS SIGNED) THEN ''VERIFIED'' ELSE ''FAILED'' END FROM yields f JOIN cells cf ON f.cell_id = cf.id, yields n JOIN cells cn ON n.cell_id = cn.id WHERE cf.name = ''factor'' AND f.field_name = ''factors'' AND f.is_frozen = 1 AND cn.name = ''target'' AND n.field_name = ''number'' AND n.is_frozen = 1',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-verify-factors', 'pc-verify-product', 'factor', 'factors');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-verify-number', 'pc-verify-product', 'target', 'number');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-verify-result', 'pc-verify-product', 'result');

-- Cell: certificate (soft — LLM writes the proof explanation)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('pc-certificate', 'proof-carry', 'certificate', 'soft',
        'Write a proof certificate. The factors found are «factors» and the verification status is «result». Explain why finding factors is computationally hard (NP) but verifying by multiplication is easy (P). This asymmetry is the foundation of public-key cryptography.',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-cert-factors', 'pc-certificate', 'factor', 'factors');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-cert-result', 'pc-certificate', 'verify-product', 'result');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-cert-report', 'pc-certificate', 'report');

CALL DOLT_COMMIT('-Am', 'pour: proof-carry');
