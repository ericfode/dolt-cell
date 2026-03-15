-- research-index: A 7-cell research DAG
--
-- DAG shape:
--   question ──→ scan-academic  ──┐
--              → scan-industry  ──┼→ cross-reference ──┐
--              → scan-patterns ──┬┘                    ├→ build-index
--                               └→ assess-for-cell ───┘
--
-- 1 hard cell (question), 6 soft cells, 3 parallel fan-out, 2 synthesis, 1 final

USE retort;

-- ── Cell: question (hard, literal) ──────────────────────────
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('ri-question', 'research-index', 'question', 'hard',
        'literal:How do production systems verify LLM outputs? Survey approaches, tools, and tradeoffs.',
        'declared');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-question-topic', 'ri-question', 'topic');

-- ── Cell: scan-academic (soft) ──────────────────────────────
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('ri-scan-academic', 'research-index', 'scan-academic', 'soft',
        'Survey academic research on «topic». List 6-8 key papers or approaches with one-sentence summaries. Format as a JSON array of objects: [{"name": "...", "approach": "...", "key_insight": "..."}].',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-scan-academic-topic', 'ri-scan-academic', 'question', 'topic');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-scan-academic-papers', 'ri-scan-academic', 'papers');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-scan-academic-1', 'ri-scan-academic', 'deterministic', 'papers is a valid JSON array', 'is_json_array');

-- ── Cell: scan-industry (soft) ──────────────────────────────
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('ri-scan-industry', 'research-index', 'scan-industry', 'soft',
        'Survey production tools and frameworks for LLM output verification. Cover Guardrails AI, NeMo Guardrails, LMQL, Guidance, Outlines, Instructor, and others you know. Format as a JSON array: [{"name": "...", "type": "...", "mechanism": "..."}].',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-scan-industry-topic', 'ri-scan-industry', 'question', 'topic');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-scan-industry-tools', 'ri-scan-industry', 'tools');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-scan-industry-1', 'ri-scan-industry', 'deterministic', 'tools is a valid JSON array', 'is_json_array');

-- ── Cell: scan-patterns (soft) ──────────────────────────────
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('ri-scan-patterns', 'research-index', 'scan-patterns', 'soft',
        'Identify recurring design patterns for verifying LLM output. Categories: structural (schema validation), semantic (meaning checks), statistical (distribution monitoring), adversarial (red-teaming), human-in-loop. For each give name, description, when to use it. JSON array format.',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-scan-patterns-topic', 'ri-scan-patterns', 'question', 'topic');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-scan-patterns-patterns', 'ri-scan-patterns', 'patterns');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-scan-patterns-1', 'ri-scan-patterns', 'deterministic', 'patterns is a valid JSON array', 'is_json_array');

-- ── Cell: cross-reference (soft, depends on all 3 scans) ───
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('ri-cross-reference', 'research-index', 'cross-reference', 'soft',
        'Cross-reference the research. For each tool in «tools», identify which patterns from «patterns» it implements and which papers from «papers» it draws from. Produce a markdown table with columns: Tool | Patterns Used | Related Papers | Gaps.',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-xref-papers', 'ri-cross-reference', 'scan-academic', 'papers');
INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-xref-tools', 'ri-cross-reference', 'scan-industry', 'tools');
INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-xref-patterns', 'ri-cross-reference', 'scan-patterns', 'patterns');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-xref-matrix', 'ri-cross-reference', 'matrix');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-xref-1', 'ri-cross-reference', 'deterministic', 'matrix is not empty', 'not_empty');

-- ── Cell: assess-for-cell (soft, depends on patterns + xref) ─
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('ri-assess', 'research-index', 'assess-for-cell', 'soft',
        'Cell uses two oracle types: deterministic (SQL checks like length_matches, is_json_array, not_empty) and semantic (LLM-judged assertions). Given the patterns in «patterns» and the landscape in «matrix», what verification approaches should Cell adopt next? Rank by impact × implementation ease. Numbered list, 5 items max.',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-assess-patterns', 'ri-assess', 'scan-patterns', 'patterns');
INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-assess-matrix', 'ri-assess', 'cross-reference', 'matrix');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-assess-recs', 'ri-assess', 'recommendations');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-assess-1', 'ri-assess', 'deterministic', 'recommendations is not empty', 'not_empty');

-- ── Cell: build-index (soft, depends on everything) ─────────
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('ri-build-index', 'research-index', 'build-index', 'soft',
        'Compile a structured research index from all upstream findings. Sections: (1) Executive Summary (3 sentences), (2) Academic Landscape [«papers»], (3) Production Tools [«tools»], (4) Design Patterns [«patterns»], (5) Cross-Reference Matrix [«matrix»], (6) Recommendations for Cell [«recommendations»]. Markdown format.',
        'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-index-papers', 'ri-build-index', 'scan-academic', 'papers');
INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-index-tools', 'ri-build-index', 'scan-industry', 'tools');
INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-index-patterns', 'ri-build-index', 'scan-patterns', 'patterns');
INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-index-matrix', 'ri-build-index', 'cross-reference', 'matrix');
INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-index-recs', 'ri-build-index', 'assess-for-cell', 'recommendations');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-index-index', 'ri-build-index', 'index');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-index-1', 'ri-build-index', 'deterministic', 'index is not empty', 'not_empty');

CALL DOLT_COMMIT('-Am', 'pour: research-index');
