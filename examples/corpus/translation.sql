-- translation: Manual pour SQL
-- Three cells: source (hard/literal, 2 yields), translate (soft), back_translate (soft with oracle)

USE retort;

INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('translation-source', 'translation', 'source', 'hard', 'literal:Hello, how are you today?', 'declared');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-source-text', 'translation-source', 'text');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-source-target_lang', 'translation-source', 'target_lang');

INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('translation-translate', 'translation', 'translate', 'soft', 'Translate «text» into «target_lang».', 'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-translate-text', 'translation-translate', 'source', 'text');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-translate-target_lang', 'translation-translate', 'source', 'target_lang');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-translate-translated', 'translation-translate', 'translated');

INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('translation-back_translate', 'translation', 'back_translate', 'soft', 'Translate «translated» back into English.', 'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-back_translate-translated', 'translation-back_translate', 'translate', 'translated');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-back_translate-round_trip', 'translation-back_translate', 'round_trip');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-back_translate-1', 'translation-back_translate', 'semantic', 'round_trip preserves the meaning of the original text', NULL);

CALL DOLT_COMMIT('-Am', 'pour: translation');
