package main

import (
	"os"
	"path/filepath"
	"testing"

	lua "github.com/yuin/gopher-lua"
)

func TestLoadLuaProgram_Haiku(t *testing.T) {
	// The bakeoff haiku.lua is a self-contained demo (runs its own Retort).
	// For ct integration, .lua files must return {cells={...}, order={...}}.
	// This test uses an inline program that matches the ct convention.
	src := `
return {
  cells = {
    topic = { kind = "hard", body = { subject = "autumn rain" } },
    compose = {
      kind = "soft",
      givens = { "topic.subject" },
      yields = { "poem" },
    },
    count = {
      kind = "compute",
      givens = { "compose.poem" },
      yields = { "total" },
    },
  },
  order = { "topic", "compose", "count" },
}
`
	tmpDir := t.TempDir()
	tmpFile := filepath.Join(tmpDir, "haiku.lua")
	if err := os.WriteFile(tmpFile, []byte(src), 0644); err != nil {
		t.Fatal(err)
	}

	cells, err := LoadLuaProgram(tmpFile)
	if err != nil {
		t.Fatalf("LoadLuaProgram failed: %v", err)
	}

	if len(cells) != 3 {
		t.Fatalf("expected 3 cells, got %d", len(cells))
	}

	t.Logf("loaded %d cells", len(cells))
	for _, c := range cells {
		t.Logf("  cell %q: bodyType=%s, givens=%d, yields=%d",
			c.name, c.bodyType, len(c.givens), len(c.yields))
	}
}

func TestLoadLuaProgram_Inline(t *testing.T) {
	// Write a minimal Lua program to a temp file
	src := `
return {
  cells = {
    topic = { kind = "hard", body = { subject = "test" } },
    compose = {
      kind = "soft",
      givens = { "topic.subject" },
      yields = { "poem" },
      effect = "replayable",
    },
    count = {
      kind = "compute",
      givens = { "compose.poem" },
      yields = { "total" },
      effect = "pure",
    },
  },
  order = { "topic", "compose", "count" },
}
`
	tmpDir := t.TempDir()
	tmpFile := filepath.Join(tmpDir, "test.lua")
	if err := os.WriteFile(tmpFile, []byte(src), 0644); err != nil {
		t.Fatal(err)
	}

	cells, err := LoadLuaProgram(tmpFile)
	if err != nil {
		t.Fatalf("LoadLuaProgram failed: %v", err)
	}

	if len(cells) != 3 {
		t.Fatalf("expected 3 cells, got %d", len(cells))
	}

	// Check topic (hard literal)
	if cells[0].name != "topic" {
		t.Errorf("cell 0 name=%q, want topic", cells[0].name)
	}
	if cells[0].bodyType != "hard" {
		t.Errorf("topic bodyType=%q, want hard", cells[0].bodyType)
	}
	if len(cells[0].yields) != 1 || cells[0].yields[0].prebound != "test" {
		t.Errorf("topic yield: got %v", cells[0].yields)
	}

	// Check compose (soft)
	if cells[1].name != "compose" {
		t.Errorf("cell 1 name=%q, want compose", cells[1].name)
	}
	if cells[1].bodyType != "soft" {
		t.Errorf("compose bodyType=%q, want soft", cells[1].bodyType)
	}
	if len(cells[1].givens) != 1 {
		t.Errorf("compose givens: got %d", len(cells[1].givens))
	}
	if cells[1].givens[0].sourceCell != "topic" || cells[1].givens[0].sourceField != "subject" {
		t.Errorf("compose given: %+v", cells[1].givens[0])
	}

	// Check count (compute → hard in schema)
	if cells[2].name != "count" {
		t.Errorf("cell 2 name=%q, want count", cells[2].name)
	}
	if cells[2].bodyType != "hard" {
		t.Errorf("count bodyType=%q, want hard (compute)", cells[2].bodyType)
	}
}

func TestNewPureVM_BlocksLoadstring(t *testing.T) {
	L := NewPureVM()
	defer L.Close()

	err := L.DoString(`return loadstring("return 1")`)
	if err == nil {
		// loadstring might return nil in pure VM
		v := L.Get(-1)
		if v != lua.LNil {
			t.Error("Pure VM should block loadstring")
		}
	}
}

func TestNewPureVM_AllowsMath(t *testing.T) {
	L := NewPureVM()
	defer L.Close()

	if err := L.DoString(`return math.abs(-42)`); err != nil {
		t.Fatalf("Pure VM should allow math: %v", err)
	}
	v := L.Get(-1)
	if n, ok := v.(lua.LNumber); !ok || float64(n) != 42 {
		t.Errorf("math.abs(-42) = %v, want 42", v)
	}
}

func TestNewPureVM_AllowsStringOps(t *testing.T) {
	L := NewPureVM()
	defer L.Close()

	if err := L.DoString(`return string.len("hello")`); err != nil {
		t.Fatalf("Pure VM should allow string ops: %v", err)
	}
	v := L.Get(-1)
	if n, ok := v.(lua.LNumber); !ok || float64(n) != 5 {
		t.Errorf("string.len('hello') = %v, want 5", v)
	}
}

func TestEffectTierFromString(t *testing.T) {
	tests := []struct {
		in   string
		want int
	}{
		{"pure", TierPure},
		{"replayable", TierReplayable},
		{"non_replayable", TierNonReplayable},
		{"nonreplayable", TierNonReplayable},
		{"PURE", TierPure},
		{"unknown", TierReplayable},
	}
	for _, tt := range tests {
		got := effectTierFromString(tt.in)
		if got != tt.want {
			t.Errorf("effectTierFromString(%q) = %d, want %d", tt.in, got, tt.want)
		}
	}
}
