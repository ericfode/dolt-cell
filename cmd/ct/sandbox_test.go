package main

import (
	"testing"
)

func TestSandbox_AllowedStatements(t *testing.T) {
	allowed := `
USE retort;
INSERT INTO cells (id, program_id, name) VALUES ('x', 'p', 'n');
INSERT INTO yields (id, cell_id, field_name) VALUES ('y', 'x', 'f');
INSERT INTO givens (id, cell_id, source_cell) VALUES ('g', 'x', 's');
INSERT INTO oracles (id, cell_id, oracle_type) VALUES ('o', 'x', 'd');
INSERT IGNORE INTO frames (id, cell_name, program_id) VALUES ('f', 'n', 'p');
UPDATE cells SET state = 'frozen' WHERE id = 'x';
CALL DOLT_COMMIT('-Am', 'pour: test');
`
	if err := sandboxSQL(allowed); err != nil {
		t.Errorf("should allow valid pour SQL: %v", err)
	}
}

func TestSandbox_BlockDropDatabase(t *testing.T) {
	if err := sandboxSQL("DROP DATABASE retort;"); err == nil {
		t.Error("should block DROP DATABASE")
	}
}

func TestSandbox_BlockDelete(t *testing.T) {
	if err := sandboxSQL("DELETE FROM cells WHERE 1=1;"); err == nil {
		t.Error("should block DELETE")
	}
}

func TestSandbox_BlockCreateUser(t *testing.T) {
	if err := sandboxSQL("CREATE USER 'hacker'@'%';"); err == nil {
		t.Error("should block CREATE USER")
	}
}

func TestSandbox_AllowSelect(t *testing.T) {
	// SELECT is allowed (hard-cell sql: bodies + cached piston output)
	if err := sandboxSQL("SELECT 1;"); err != nil {
		t.Errorf("should allow SELECT: %v", err)
	}
}

func TestSandbox_BlockTruncate(t *testing.T) {
	if err := sandboxSQL("TRUNCATE TABLE cells;"); err == nil {
		t.Error("should block TRUNCATE")
	}
}

func TestSandbox_MixedValid(t *testing.T) {
	mixed := `INSERT INTO cells (id) VALUES ('x');
DROP DATABASE retort;`
	if err := sandboxSQL(mixed); err == nil {
		t.Error("should block mixed SQL with dangerous statement")
	}
}

func TestSandbox_EmptyOK(t *testing.T) {
	if err := sandboxSQL(""); err != nil {
		t.Errorf("empty SQL should be ok: %v", err)
	}
}

func TestSandbox_QuotedSemicolons(t *testing.T) {
	// Values containing semicolons should not split
	sql := `INSERT INTO cells (id, body) VALUES ('x', 'SELECT 1; DROP TABLE foo');`
	if err := sandboxSQL(sql); err != nil {
		t.Errorf("should handle quoted semicolons: %v", err)
	}
}
