package syntax

import "testing"

func TestParseGroups(t *testing.T) {
	for pat, want := range map[string]int{"": 0, "abc": 0, "(a)(b(c))": 3, "()|()": 2, `\(a\)`: 0, `[(]`: 0} {
		if _, n, err := Parse(pat); err != nil || n != want {
			t.Errorf("Parse(%q) = %d groups, err %v; want %d", pat, n, err, want)
		}
	}
}

func TestParseRepeat(t *testing.T) {
	for _, tc := range []struct {
		pat      string
		min, max int
	}{
		{"a*", 0, Unbounded}, {"a+", 1, Unbounded}, {"a?", 0, 1}, {"a{3}", 3, 3},
		{"a{3,}", 3, Unbounded}, {"a{0,0}", 0, 0}, {"a{2,10}", 2, 10},
	} {
		n, _, err := Parse(tc.pat)
		if err != nil || n.Kind != KindRepeat || n.Min != tc.min || n.Max != tc.max {
			t.Errorf("Parse(%q) = %+v, %v", tc.pat, n, err)
		}
	}
}

func TestParseClass(t *testing.T) {
	has := func(pat string, in, out string) {
		t.Helper()
		n, _, err := Parse(pat)
		if err != nil || n.Kind != KindClass {
			t.Fatalf("Parse(%q) = %+v, %v", pat, n, err)
		}
		for _, c := range []byte(in) {
			if !n.Set.Has(c) {
				t.Errorf("%s should contain %q", pat, c)
			}
		}
		for _, c := range []byte(out) {
			if n.Set.Has(c) {
				t.Errorf("%s should not contain %q", pat, c)
			}
		}
	}
	has(`[a-c]`, "abc", "dA-")
	has(`[-a]`, "-a", "b")
	has(`[a-]`, "-a", "b")
	has(`[a\-z]`, "a-z", "b")
	has(`[^a-c]`, "dA-", "abc")
	has(`[a^]`, "a^", "b")
	has(`[\w-]`, "a_9-", "!")
	has(`[\]\\]`, `]\`, "a")
	has(`\D`, "a ", "5")
	has(`\s`, " \t", "a")
	has(`[^\s]`, "a", " ")
}

func TestParseAlternationShape(t *testing.T) {
	n, _, err := Parse("a|b|")
	if err != nil || n.Kind != KindAlternate || len(n.Subs) != 3 || n.Subs[2].Kind != KindEmpty {
		t.Errorf("unexpected tree %+v (%v)", n, err)
	}
}
