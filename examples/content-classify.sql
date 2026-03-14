-- Pour SQL for content-classify: Content Classification with Semantic Dispatch
-- LLM classifies text semantically (impossible in SQL), hard cell validates label format
USE retort;

-- Cell: input (hard, pre-bound literal)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('cc-input', 'content-classify', 'input', 'hard',
        'literal:I strongly disagree with your analysis and think the methodology is fundamentally flawed.',
        'declared');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-input-text', 'cc-input', 'text');

-- Cell: classify (soft — LLM determines semantic category)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('cc-classify', 'content-classify', 'classify', 'soft',
        'Classify this text into exactly one category — clean, borderline, or toxic:\n\n«text»\n\nConsider tone, intent, and potential for harm. Constructive criticism is clean. Aggressive personal attacks are toxic. Ambiguous cases are borderline. Return ONLY the single word: clean, borderline, or toxic.',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-classify-text', 'cc-classify', 'input', 'text');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-classify-label', 'cc-classify', 'label');

-- Cell: validate-label (hard — SQL checks label is one of three valid values)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('cc-validate-label', 'content-classify', 'validate-label', 'hard',
        'sql:SELECT CASE WHEN LOWER(TRIM(l.value_text)) IN (''clean'', ''borderline'', ''toxic'') THEN ''valid'' ELSE ''invalid'' END FROM yields l JOIN cells c ON l.cell_id = c.id WHERE c.name = ''classify'' AND l.field_name = ''label'' AND l.is_frozen = 1',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-validate-label', 'cc-validate-label', 'classify', 'label');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-validate-is-valid', 'cc-validate-label', 'is-valid');

-- Cell: respond (soft — LLM generates appropriate response based on classification)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('cc-respond', 'content-classify', 'respond', 'soft',
        'The text was classified as «label» (validation: «is-valid»). Generate the appropriate response:\n\n- If clean: acknowledge the feedback constructively and thank the user for their input\n- If borderline: acknowledge the concern but ask the user to rephrase more constructively\n- If toxic: issue a moderation notice explaining why the content was flagged and what policy it violates\n\nChoose the response matching the classification «label».',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-respond-label', 'cc-respond', 'classify', 'label');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-respond-text', 'cc-respond', 'input', 'text');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-respond-valid', 'cc-respond', 'validate-label', 'is-valid');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-respond-action', 'cc-respond', 'action');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-respond-1', 'cc-respond', 'deterministic',
        'action is not empty', 'not_empty');

CALL DOLT_COMMIT('-Am', 'pour: content-classify');
