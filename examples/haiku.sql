-- Pour SQL for haiku: Creative Writing
-- LLM writes poetry (impossible in SQL), hard cell counts word structure
USE retort;

-- Cell: topic (hard, pre-bound literal)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('hk-topic', 'haiku', 'topic', 'hard',
        'literal:autumn rain on a temple roof', 'declared');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-topic-subject', 'hk-topic', 'subject');

-- Cell: compose (soft — LLM writes the haiku)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('hk-compose', 'haiku', 'compose', 'soft',
        'Write a haiku about «subject». Follow the traditional 5-7-5 syllable structure across exactly three lines. Return only the three lines of the haiku, separated by newlines.',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-compose-subject', 'hk-compose', 'topic', 'subject');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-compose-poem', 'hk-compose', 'poem');

-- Cell: count-words (hard — SQL counts words in the poem)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('hk-count-words', 'haiku', 'count-words', 'hard',
        'sql:SELECT LENGTH(TRIM(p.value_text)) - LENGTH(REPLACE(TRIM(p.value_text), '' '', '''')) + 1 FROM yields p JOIN cells c ON p.cell_id = c.id WHERE c.name = ''compose'' AND p.field_name = ''poem'' AND p.is_frozen = 1',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-count-poem', 'hk-count-words', 'compose', 'poem');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-count-total', 'hk-count-words', 'total');

-- Cell: critique (soft — LLM evaluates the haiku's quality)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('hk-critique', 'haiku', 'critique', 'soft',
        'Critique this haiku (word count: «total»):\n\n«poem»\n\nEvaluate: Does it follow 5-7-5 syllable structure? Does the imagery evoke the subject? Is there a seasonal reference (kigo)? Is there a cutting word (kireji) or pause between images? Rate overall quality from 1-5.',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-critique-poem', 'hk-critique', 'compose', 'poem');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-critique-total', 'hk-critique', 'count-words', 'total');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-critique-review', 'hk-critique', 'review');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-critique-1', 'hk-critique', 'semantic',
        'review contains at least 2 sentences', NULL);

CALL DOLT_COMMIT('-Am', 'pour: haiku');
