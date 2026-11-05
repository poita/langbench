package glob_test

import (
	"testing"

	"buildsys/glob"
)

func TestMatch(t *testing.T) {
	type c struct {
		pat, s string
		want   bool
	}
	cases := []c{
		{"src/*.txt", "src/a.txt", true},
		{"src/*.txt", "src/.txt", true},
		{"src/*.txt", "src/sub/a.txt", false},
		{"src/*.txt", "a.txt", false},
		{"src/**", "src/a.txt", true},
		{"src/**", "src/x/y/z.txt", true},
		{"src/**", "src", true},
		{"src/**", "other/a.txt", false},
		{"src/**", "srcx", false},
		{"**/*.txt", "a.txt", true},
		{"**/*.txt", "src/a.txt", true},
		{"**/*.txt", "a/b/c.txt", true},
		{"**/*.txt", "a.text", false},
		{"src/**/t_*.txt", "src/t_1.txt", true},
		{"src/**/t_*.txt", "src/a/b/t_2.txt", true},
		{"src/**/t_*.txt", "src/t.txt", false},
		{"src/?.txt", "src/a.txt", true},
		{"src/?.txt", "src/ab.txt", false},
		{"src/[ab]*.txt", "src/a1.txt", true},
		{"src/[ab]*.txt", "src/b.txt", true},
		{"src/[ab]*.txt", "src/c.txt", false},
		{"src/[!ab]*.txt", "src/c.txt", true},
		{"src/[!ab]*.txt", "src/a.txt", false},
		{"src/[0-9].txt", "src/7.txt", true},
		{"src/[0-9].txt", "src/x.txt", false},
		{"a**b", "axyzb", true},
		{"a**b", "ab", true},
		{"a**b", "a/b", false},
		{"[-a]", "-", true},
		{"[a-]", "-", true},
		{"[*?]", "*", true},
		{"[*?]", "x", false},
		{"*", "", true},
		{"**", "", true},
		{"?", "", false},
		{"*", "a//b", false},
		{"**", "a//b", true},
		{"a/*/b", "a//b", true},
		{"**/**", "a/b", true},
		{"a/**/**/b", "a/b", true},
		{"a/**/b", "a/x/y/b", true},
		{"a/**/b", "a/x/y/c", false},
		{"*a*b*", "xxaxxbxx", true},
		{"*a*b*", "xxbxxaxx", false},
		{"**/x/**", "p/x", true},
		{"**/x/**", "p/q/x/r/s", true},
		{"**/x/**", "p/q", false},
	}
	for _, tc := range cases {
		p, ok := glob.Compile(tc.pat)
		if !ok {
			t.Errorf("Compile(%q) failed", tc.pat)
			continue
		}
		if got := p.Match(tc.s); got != tc.want {
			t.Errorf("Match(%q, %q) = %v, want %v", tc.pat, tc.s, got, tc.want)
		}
	}
}

func TestMalformed(t *testing.T) {
	for _, pat := range []string{"", "/a", "a/", "a//b", "[", "[]", "[!]", "[abc", "[z-a]", "a/[b", "/"} {
		if _, ok := glob.Compile(pat); ok {
			t.Errorf("Compile(%q) accepted", pat)
		}
	}
	// A '-' directly before ']' is a literal, not a range.
	for _, pat := range []string{"[a-]", "[-a]", "[!a-]", "[a-c]"} {
		if _, ok := glob.Compile(pat); !ok {
			t.Errorf("Compile(%q) rejected", pat)
		}
	}
}

func TestLiteralPrefix(t *testing.T) {
	for pat, want := range map[string]string{
		"src/**":        "src",
		"src/a/*.txt":   "src/a",
		"src/a/b.txt":   "src/a/b.txt",
		"**":            "",
		"*/x":           "",
		"a/[b]/c":       "a",
		"a/b?/c":        "a",
		"x/**/y":        "x",
		"deep/er/*/z/q": "deep/er",
	} {
		p, ok := glob.Compile(pat)
		if !ok {
			t.Fatal(pat)
		}
		if got := p.LiteralPrefix(); got != want {
			t.Errorf("LiteralPrefix(%q) = %q, want %q", pat, got, want)
		}
	}
}
