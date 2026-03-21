# Cell Next Phase: Design Decisions

Answers from Seven Sages consul, 2026-03-17.

1. **Schema versioning**: Schema epoch integer in `retort_meta` singleton table. Piston registration checks epoch; mismatch = refuse to start. Stop-and-restart, no live migration.

2. **cell-zero-eval spawn**: Accept as bootstrap artifact. Replace raw INSERTs with `CALL cell_create_frame()` stored procedure for FK safety. Keep SQL-template structure in body.

3. **Oracle atomicity**: Async. Judge verdicts are normal cells wired as givens. DAG ordering handles sequencing. No blocking oracle operation.

4. **Editing programs**: `ct thaw <program> <cell>` creates gen N+1 frames for target + transitive dependents. Same mechanism as stem respawn. Append-only preserved.

5. **Piston prompt**: ct-only interface. Remove all raw SQL from system-prompt. ~290 → ~80 lines. Schema details hidden behind ct commands.

6. **Target audience**: Developer tool for Gas Town agents/overseer. Show frame IDs, SQL errors. No GUI or simplified layer this phase.
