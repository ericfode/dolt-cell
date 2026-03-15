USE retort;

-- Cell: survey-state (soft, no deps — reads files directly)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('cr-survey-state', 'cell-research', 'survey-state', 'soft',
'Read the current Cell runtime design and implementation state. Key files to read: docs/plans/2026-03-14-cell-repl-design-v2.md (architecture), docs/plans/2026-03-14-retort-schema-v2.md (database schema), docs/plans/2026-03-14-cell-pour-design.md (parser bootstrap), docs/plans/2026-03-14-oracle-system-design.md (verification), docs/plans/2026-03-14-crystallization-design.md (soft to hard), cmd/ct/main.go (the CLI tool), schema/procedures.sql (stored procedures), poc/test-poc.sh (what was tested). Produce a structured summary: what is BUILT and working, what is DESIGNED but not built, and what is UNDESIGNED (known gaps). Be specific — cite file names and line counts.',
'declared');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-survey-state-summary', 'cr-survey-state', 'summary');

-- Cell: survey-reviews (soft, no deps — reads review files)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('cr-survey-reviews', 'cell-research', 'survey-reviews', 'soft',
'Read the adversarial review documents and extract unresolved concerns: docs/reviews/mara-v2-review.md, docs/reviews/deng-v2-review.md, docs/reviews/ravi-v2-review.md, docs/reviews/kai-v2-review.md, docs/reviews/priya-v2-review.md. For each reviewer, list: (1) their v1 concerns that v2 resolved, (2) NEW concerns they raised in v2, (3) whether those new concerns have been addressed by subsequent work. Focus on concerns that are still OPEN.',
'declared');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-survey-reviews-findings', 'cr-survey-reviews', 'findings');

-- Cell: identify-gaps (soft, depends on both surveys)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('cr-identify-gaps', 'cell-research', 'identify-gaps', 'soft',
'Given the state of what is built and the unresolved review concerns, identify the 5 most critical gaps. For each gap: What is missing? Why does it matter? How hard is it to fix? Who should fix it? Rank by impact times feasibility.',
'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-gaps-summary', 'cr-identify-gaps', 'survey-state', 'summary');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-gaps-findings', 'cr-identify-gaps', 'survey-reviews', 'findings');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-identify-gaps-gaps', 'cr-identify-gaps', 'gaps');

-- Cell: research-prior-art (soft, depends on gaps)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('cr-research-prior-art', 'cell-research', 'research-prior-art', 'soft',
'For the top 3 gaps identified, research how other systems solve the same problem. Search the web for prior art. Consider: reactive dataflow systems, database-as-runtime approaches, LLM orchestration systems, academic literature. For each gap, provide 2-3 concrete approaches from prior art with tradeoffs.',
'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-research-gaps', 'cr-research-prior-art', 'identify-gaps', 'gaps');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-research-research', 'cr-research-prior-art', 'research');

-- Cell: synthesize (soft, depends on gaps + research)
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('cr-synthesize', 'cell-research', 'synthesize', 'soft',
'Given the gaps and prior art research, write a concrete plan for the next sprint of Cell development. The plan should have exactly 5 items ordered by priority. For each item: what to build, why it matters, estimated effort, concrete acceptance criteria, and which files/procedures to modify. This plan should be immediately actionable.',
'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-synth-gaps', 'cr-synthesize', 'identify-gaps', 'gaps');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-synth-research', 'cr-synthesize', 'research-prior-art', 'research');

INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-synthesize-plan', 'cr-synthesize', 'plan');

CALL DOLT_COMMIT('-Am', 'pour: cell-research');
