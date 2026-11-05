package analysis

import (
	"reflect"
	"testing"
)

func spans(text string) []string {
	var out []string
	b := []byte(text)
	for pos := 0; ; {
		s, e, ok := Next(b, pos)
		if !ok {
			return out
		}
		out = append(out, text[s:e])
		pos = e
	}
}

func TestTokenise(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"The cat sat.", []string{"The", "cat", "sat"}},
		{"don't stop", []string{"don't", "stop"}},
		{"'quoted'", []string{"quoted"}},
		{"rock'n'roll", []string{"rock'n'roll"}},
		{"a''b", []string{"a", "b"}},
		{"well-known", []string{"well", "known"}},
		{"Version 1.2.3", []string{"Version", "1", "2", "3"}},
		{"X1 XY2Z", []string{"X1", "XY2Z"}},
		{"Don’t", []string{"Don’t"}},
		{"a× b÷c", []string{"a", "b", "c"}},
		{"Café ΑΒΓ Привет — x", []string{"Café", "ΑΒΓ", "Привет", "x"}},
		{"日本語 abc", []string{"abc"}},
		{"it’s’ ", []string{"it’s"}},
		{"", nil},
		{"   ", nil},
		{"x'", []string{"x"}},
	}
	for _, c := range cases {
		if got := spans(c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("tokens(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestFold(t *testing.T) {
	cases := map[string]string{"Don’t": "dont", "don't": "dont", "CAFÉ": "cafÉ", "Café": "café", "A1B": "a1b"}
	for in, want := range cases {
		if got := string(Fold(nil, []byte(in))); got != want {
			t.Errorf("Fold(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestTerms(t *testing.T) {
	got := Terms("The quick brown fox jumps over the lazy dog.")
	want := []string{"the", "quick", "brown", "fox", "jump", "over", "the", "lazi", "dog"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q", got)
	}
	// Tokens with digits or non-ASCII letters are never stemmed.
	got = Terms("running2 cafés runnings")
	want = []string{"running2", "cafés", "run"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q", got)
	}
}

func TestStopWords(t *testing.T) {
	for _, w := range []string{"the", "a", "with", "their"} {
		if !IsStopWord(w) {
			t.Errorf("%q should be a stop word", w)
		}
	}
	for _, w := range []string{"cat", "The", "from"} {
		if IsStopWord(w) {
			t.Errorf("%q should not be a stop word", w)
		}
	}
}
