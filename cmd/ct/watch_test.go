package main

import "testing"

func TestTrunc_ASCII(t *testing.T) {
	if got := trunc("hello world", 5); got != "hello..." {
		t.Errorf("trunc ASCII: got %q, want %q", got, "hello...")
	}
}

func TestTrunc_NoTruncNeeded(t *testing.T) {
	if got := trunc("hi", 10); got != "hi" {
		t.Errorf("trunc no-op: got %q, want %q", got, "hi")
	}
}

func TestTrunc_Unicode(t *testing.T) {
	// 4 runes, trunc to 2 should not break mid-rune
	s := "日本語文"
	got := trunc(s, 2)
	want := "日本..."
	if got != want {
		t.Errorf("trunc unicode: got %q, want %q", got, want)
	}
}

func TestTrunc_ExactLength(t *testing.T) {
	if got := trunc("abcde", 5); got != "abcde" {
		t.Errorf("trunc exact: got %q, want %q", got, "abcde")
	}
}

func TestTrunc_Empty(t *testing.T) {
	if got := trunc("", 5); got != "" {
		t.Errorf("trunc empty: got %q, want %q", got, "")
	}
}

func TestTrunc_ZeroWidth(t *testing.T) {
	if got := trunc("hello", 0); got != "..." {
		t.Errorf("trunc zero: got %q, want %q", got, "...")
	}
}
