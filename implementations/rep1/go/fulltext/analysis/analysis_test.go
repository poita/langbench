package analysis

import (
	"reflect"
	"testing"
)

func texts(toks []Token) []string {
	out := make([]string, 0, len(toks))
	for _, t := range toks {
		out = append(out, t.Text)
	}
	return out
}

func TestTokenise(t *testing.T) {
	tests := []struct {
		in   string
		want []string
	}{
		{"The cat sat.", []string{"the", "cat", "sat"}},
		{"don't stop", []string{"dont", "stop"}},
		{"'quoted'", []string{"quoted"}},
		{"rock'n'roll", []string{"rocknroll"}},
		{"a''b", []string{"a", "b"}},
		{"well-known", []string{"well", "known"}},
		{"Version 1.2.3", []string{"version", "1", "2", "3"}},
		{"X1 XY2Z", []string{"x1", "xy2z"}},
		{"Don’t", []string{"dont"}},
		{"Café CAFÉ", []string{"café", "cafÉ"}},
		{"3 × 4 ÷ 2", []string{"3", "4", "2"}},
		{"日本語 abc", []string{"abc"}},
		{"", []string{}},
	}
	a := NewAnalyzer()
	for _, tc := range tests {
		if got := texts(a.Analyze(tc.in)); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("Analyze(%q) texts = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestSpans(t *testing.T) {
	text := "  Don’t go, é!"
	toks := NewAnalyzer().Analyze(text)
	var got []string
	for _, tk := range toks {
		got = append(got, text[tk.Start:tk.End])
	}
	want := []string{"Don’t", "go", "é"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("spans = %q, want %q", got, want)
	}
}

func TestTerms(t *testing.T) {
	got := NewAnalyzer().Terms("Running dogs' 2nd café")
	want := []string{"run", "dog", "2nd", "café"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Terms = %q, want %q", got, want)
	}
}

func TestStopWords(t *testing.T) {
	for _, w := range []string{"the", "to", "with", "their"} {
		if !IsStopWord(w) {
			t.Errorf("%q should be a stop word", w)
		}
	}
	for _, w := range []string{"cat", "The", "", "has"} {
		if IsStopWord(w) {
			t.Errorf("%q should not be a stop word", w)
		}
	}
	if len(stopWords) != 33 {
		t.Errorf("stop word count = %d, want 33", len(stopWords))
	}
}

func TestIsSpace(t *testing.T) {
	for _, r := range []rune{'\t', '\n', '\v', '\f', '\r', ' ', '\u00a0'} {
		if !IsSpace(r) {
			t.Errorf("IsSpace(%U) = false", r)
		}
	}
	if IsSpace('\u2003') || IsSpace('a') {
		t.Error("unexpected space")
	}
}
