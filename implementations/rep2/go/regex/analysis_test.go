package regexvm

import "testing"

func tree(t *testing.T, p string) *node {
	t.Helper()
	n, _, err := parse(p)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func TestAnchored(t *testing.T) {
	cases := map[string]bool{
		"^a": true, "^a|^b": true, "^a|b": false, "(^a)": true, "(^a)+": true,
		"(^a)*": false, "a^": false, "": false, "(^a|b)": false, "a": false,
	}
	for p, want := range cases {
		if got := tree(t, p).anchored(); got != want {
			t.Errorf("anchored(%q) = %v, want %v", p, got, want)
		}
	}
}

func TestNullableAndFirst(t *testing.T) {
	cases := []struct {
		pat      string
		nullable bool
		first    string
	}{
		{"abc", false, "a"},
		{"a*b", false, "ab"},
		{"a?b?", true, "ab"},
		{"^$", true, ""},
		{"(a|)b", false, "ab"},
		{"x{0}y", false, "y"},
		{"[a-c]|z", false, "abcz"},
		{"", true, ""},
	}
	for _, c := range cases {
		var set charSet
		nl := tree(t, c.pat).first(&set)
		if nl != c.nullable || nl != tree(t, c.pat).nullable() {
			t.Errorf("%q: nullable = %v, want %v", c.pat, nl, c.nullable)
		}
		var want charSet
		for i := 0; i < len(c.first); i++ {
			want[c.first[i]] = true
		}
		for i := range want {
			if want[i] && !set[i] {
				t.Errorf("%q: first set misses %q", c.pat, rune(i))
			}
		}
	}
}
