-- classify: Manual pour SQL
-- Two cells: input (hard/literal), classify (soft with 2 oracles, 2 yields)

USE retort;

INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('classify-input', 'classify', 'input', 'hard', 'literal:The service was terrible and I want a refund immediately!', 'declared');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-input-text', 'classify-input', 'text');

INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('classify-classify', 'classify', 'classify', 'soft', 'Classify the sentiment of «text» as one of: positive, negative, neutral. Also provide a confidence score from 0.0 to 1.0.', 'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-classify-text', 'classify-classify', 'input', 'text');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-classify-sentiment', 'classify-classify', 'sentiment');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-classify-confidence', 'classify-classify', 'confidence');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-classify-1', 'classify-classify', 'semantic', 'sentiment is one of positive, negative, or neutral', NULL);

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-classify-2', 'classify-classify', 'semantic', 'confidence is a number between 0.0 and 1.0', NULL);

CALL DOLT_COMMIT('-Am', 'pour: classify');
