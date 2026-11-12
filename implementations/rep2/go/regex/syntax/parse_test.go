package syntax

import (
	"errors"
	"testing"
)

func TestParseShape(t *testing.T) {
	tests := []struct {
		pattern string
		want    string
		groups  int
	}{
		{"", "", 0},
		{"abc", `<'a''b''c'>`, 0},
		{"a|b|", `('a'|'b'|)`, 0},
		{"(a|(b))+", `{#1(('a'|#2('b')))}1,`, 2},
		{"a{2,3}", `{'a'}2,3`, 0},
		{"a{0}", `{'a'}0,0`, 0},
		{"x{4,}", `{'x'}4,`, 0},
		{"a?b*", `<{'a'}0,1{'b'}0,>`, 0},
		{`\.\\\ `, `<'.''\\'' '>`, 0},
		{"^a$", `<^'a'$>`, 0},
		{"()", `#1()`, 1},
	}
	for _, tc := range tests {
		n, g, err := Parse(tc.pattern)
		if err != nil {
			t.Errorf("Parse(%q): %v", tc.pattern, err)
			continue
		}
		if got := n.String(); got != tc.want || g != tc.groups {
			t.Errorf("Parse(%q) = %s, %d groups; want %s, %d", tc.pattern, got, g, tc.want, tc.groups)
		}
	}
}

func classOf(t *testing.T, pattern string) CharSet {
	t.Helper()
	n, _, err := Parse(pattern)
	if err != nil {
		t.Fatalf("Parse(%q): %v", pattern, err)
	}
	if n.Kind != Class {
		t.Fatalf("Parse(%q) is %v, not a class", pattern, n.Kind)
	}
	return n.Set
}

func members(s CharSet) string {
	var b []byte
	for c := 0; c < 256; c++ {
		if s.Has(byte(c)) {
			b = append(b, byte(c))
		}
	}
	return string(b)
}

func TestClasses(t *testing.T) {
	tests := []struct{ pattern, want string }{
		{"[abc]", "abc"},
		{"[a-c]", "abc"},
		{"[-a]", "-a"},
		{"[a-]", "-a"},
		{`[a\-c]`, "-ac"},
		{"[+--]", "+,-"},
		{"[a^]", "^a"},
		{`[\]\\]`, `\]`},
		{`[\d]`, "0123456789"},
		{`[\s]`, "\t\n\v\f\r "},
		{"[0-2a-b]", "012ab"},
		{`\d`, "0123456789"},
	}
	for _, tc := range tests {
		if got := members(classOf(t, tc.pattern)); got != tc.want {
			t.Errorf("%s: members %q, want %q", tc.pattern, got, tc.want)
		}
	}
}

func TestNegatedClasses(t *testing.T) {
	s := classOf(t, `[^a-c]`)
	for _, c := range []byte("abc") {
		if s.Has(c) {
			t.Errorf("[^a-c] contains %q", c)
		}
	}
	if !s.Has('d') || !s.Has(0) || !s.Has(255) {
		t.Error("[^a-c] should contain everything else")
	}
	d := classOf(t, `\D`)
	if d.Has('5') || !d.Has('x') || !d.Has(' ') {
		t.Error(`\D wrong`)
	}
	if w := classOf(t, `\W`); w.Has('_') || w.Has('Z') || !w.Has('-') {
		t.Error(`\W wrong`)
	}
	if s := classOf(t, `\S`); s.Has(' ') || !s.Has('a') {
		t.Error(`\S wrong`)
	}
}

func TestErrors(t *testing.T) {
	bad := []string{
		"(", ")", "a)", "(a", "[", "[a", "[]", "[^]", "*", "+a", "a**", "a+?", "?",
		"{2}", "a{", "a{x}", "a{2", "a{3,2}", "a{1001}", "^*", "$+", `\`, `\q`, `\1`,
		"[z-a]", `[\q]`, "|*", "(*)", "]", "}", "a{,3}",
	}
	for _, p := range bad {
		_, _, err := Parse(p)
		if err == nil {
			t.Errorf("Parse(%q) succeeded, want error", p)
			continue
		}
		var se *Error
		if !errors.As(err, &se) {
			t.Errorf("Parse(%q) error %T is not *Error", p, err)
		}
	}
}

func TestDepthLimit(t *testing.T) {
	deep := ""
	for i := 0; i < MaxDepth+1; i++ {
		deep += "("
	}
	for i := 0; i < MaxDepth+1; i++ {
		deep += ")"
	}
	if _, _, err := Parse(deep); err == nil {
		t.Error("expected nesting error")
	}
}

func TestCanBeEmpty(t *testing.T) {
	tests := map[string]bool{
		"a": false, "": true, "a*": true, "a+": false, "(a|)": true, "^": true,
		"a{0}": true, "(a*)+": true, "ab": false, "a?b": false, ".": false,
	}
	for p, want := range tests {
		n, _, err := Parse(p)
		if err != nil {
			t.Fatal(err)
		}
		if got := n.CanBeEmpty(); got != want {
			t.Errorf("CanBeEmpty(%q) = %v, want %v", p, got, want)
		}
	}
}
