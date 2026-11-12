package lex

import "testing"

func TestCollapse(t *testing.T) {
	for in, want := range map[string]string{
		"  a \t b  ": "a b",
		"":           "",
		"   ":        "",
		"a":          "a",
		"a\t\tb":     "a b",
	} {
		if got := Collapse(in); got != want {
			t.Errorf("Collapse(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSkipComment(t *testing.T) {
	tests := []struct {
		in   string
		want int
	}{
		{"(a) b", 3},
		{"(a (b) c) d", 9},
		{`(a \) b) c`, 8},
		{"(unterminated", 13},
		{"(é) x", 4},
	}
	for _, tc := range tests {
		if got := SkipComment(tc.in, 0); got != tc.want {
			t.Errorf("SkipComment(%q) = %d, want %d", tc.in, got, tc.want)
		}
	}
}

func TestQuotedString(t *testing.T) {
	tests := []struct {
		in   string
		text string
		next int
	}{
		{`"abc" x`, "abc", 5},
		{`"a\"b"`, `a"b`, 6},
		{`"a\\"`, `a\`, 5},
		{`"open`, "open", 5},
		{`"trailing\`, `trailing\`, 10},
		{`"é\é"`, "éé", 7},
	}
	for _, tc := range tests {
		text, next := QuotedString(tc.in, 0)
		if text != tc.text || next != tc.next {
			t.Errorf("QuotedString(%q) = %q,%d want %q,%d", tc.in, text, next, tc.text, tc.next)
		}
	}
}
