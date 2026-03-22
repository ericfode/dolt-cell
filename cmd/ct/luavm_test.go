package main

import (
	"strings"
	"testing"
)

func TestLoadLuaProgram_Haiku(t *testing.T) {
	cells, err := loadLuaProgram("../../examples/haiku.lua")
	if err != nil {
		t.Fatalf("loadLuaProgram: %v", err)
	}
	if len(cells) != 4 {
		t.Fatalf("expected 4 cells, got %d", len(cells))
	}

	// topic: hard cell with prebound subject
	topic := cells[0]
	if topic.name != "topic" {
		t.Errorf("cells[0].name = %q, want topic", topic.name)
	}
	if topic.bodyType != "hard" {
		t.Errorf("topic.bodyType = %q, want hard", topic.bodyType)
	}
	if len(topic.yields) != 1 || topic.yields[0].fieldName != "subject" {
		t.Errorf("topic yields = %v", topic.yields)
	}
	if topic.yields[0].prebound == "" {
		t.Error("topic.subject should be prebound")
	}

	// compose: soft cell with Lua body
	compose := cells[1]
	if compose.name != "compose" {
		t.Errorf("cells[1].name = %q, want compose", compose.name)
	}
	if compose.bodyType != "soft" {
		t.Errorf("compose.bodyType = %q, want soft", compose.bodyType)
	}
	if !strings.HasPrefix(compose.body, "lua:") {
		t.Errorf("compose.body should start with 'lua:'")
	}
	if len(compose.givens) != 1 || compose.givens[0].sourceCell != "topic" {
		t.Errorf("compose givens = %v", compose.givens)
	}

	// count_words: compute (hard) cell with Lua body
	cw := cells[2]
	if cw.name != "count_words" {
		t.Errorf("cells[2].name = %q, want count_words", cw.name)
	}
	if cw.bodyType != "hard" {
		t.Errorf("count_words.bodyType = %q, want hard", cw.bodyType)
	}
	if !strings.HasPrefix(cw.body, "lua:") {
		t.Errorf("count_words.body should start with 'lua:'")
	}
}

func TestEvalLuaCompute_CountWords(t *testing.T) {
	cells, err := loadLuaProgram("../../examples/haiku.lua")
	if err != nil {
		t.Fatalf("loadLuaProgram: %v", err)
	}
	var body string
	for _, c := range cells {
		if c.name == "count_words" {
			body = c.body
		}
	}
	if body == "" {
		t.Fatal("count_words cell not found")
	}

	tests := []struct {
		poem  string
		count string
	}{
		{"hello world foo", "3"},
		{"one two three four five", "5"},
		{"single", "1"},
	}
	for _, tt := range tests {
		result, err := evalLuaCompute(body, map[string]string{"poem": tt.poem})
		if err != nil {
			t.Errorf("evalLuaCompute(%q): %v", tt.poem, err)
			continue
		}
		if result["total"] != tt.count {
			t.Errorf("word count of %q = %q, want %s", tt.poem, result["total"], tt.count)
		}
	}
}

func TestEvalLuaSoftPrompt_Compose(t *testing.T) {
	cells, err := loadLuaProgram("../../examples/haiku.lua")
	if err != nil {
		t.Fatalf("loadLuaProgram: %v", err)
	}
	var body string
	for _, c := range cells {
		if c.name == "compose" {
			body = c.body
		}
	}
	if body == "" {
		t.Fatal("compose cell not found")
	}

	env := map[string]string{
		"topic.subject": "autumn rain",
		"subject":       "autumn rain",
	}
	prompt, err := evalLuaSoftPrompt(body, env)
	if err != nil {
		t.Fatalf("evalLuaSoftPrompt: %v", err)
	}
	if !strings.Contains(prompt, "autumn rain") {
		t.Errorf("prompt should mention subject, got: %q", prompt[:minLen(100, len(prompt))])
	}
	if len(prompt) < 10 {
		t.Errorf("prompt too short: %q", prompt)
	}
}

func minLen(a, b int) int {
	if a < b {
		return a
	}
	return b
}
