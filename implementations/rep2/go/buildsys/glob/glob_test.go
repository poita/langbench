package glob

import "testing"

func TestMatch(t *testing.T) {
	tests := []struct {
		pat string
		yes []string
		no  []string
	}{
		{"src/*.txt", []string{"src/a.txt", "src/.txt"}, []string{"src/sub/a.txt", "a.txt"}},
		{"src/**", []string{"src/a.txt", "src/x/y/z.txt", "src"}, []string{"other/a.txt", "srcx"}},
		{"**/*.txt", []string{"a.txt", "src/a.txt", "a/b/c.txt"}, []string{"a.text"}},
		{"src/**/t_*.txt", []string{"src/t_1.txt", "src/a/b/t_2.txt"}, []string{"src/t.txt"}},
		{"src/?.txt", []string{"src/a.txt"}, []string{"src/ab.txt"}},
		{"src/[ab]*.txt", []string{"src/a1.txt", "src/b.txt"}, []string{"src/c.txt"}},
		{"src/[!ab]*.txt", []string{"src/c.txt"}, []string{"src/a.txt"}},
		{"src/[0-9].txt", []string{"src/7.txt"}, []string{"src/x.txt"}},
		{"a**b", []string{"axyzb", "ab"}, []string{"a/b"}},
		{"*", []string{"", "abc"}, []string{"a/b", "a//b"}},
		{"**", []string{"", "a", "a//b", "x/"}, nil},
		{"?", nil, []string{""}},
		{"[-a]", []string{"-", "a"}, []string{"b"}},
		{"[a-]", []string{"-", "a"}, []string{"b"}},
		{"[*?]", []string{"*", "?"}, []string{"a"}},
		{"a/*/c", []string{"a//c", "a/b/c"}, []string{"a/c", "a/b/b/c"}},
	}
	for _, tc := range tests {
		p, err := Compile(tc.pat)
		if err != nil {
			t.Fatalf("Compile(%q): %v", tc.pat, err)
		}
		for _, s := range tc.yes {
			if !p.Match(s) {
				t.Errorf("%q should match %q", tc.pat, s)
			}
		}
		for _, s := range tc.no {
			if p.Match(s) {
				t.Errorf("%q should not match %q", tc.pat, s)
			}
		}
	}
}

func TestBadPatterns(t *testing.T) {
	for _, pat := range []string{"", "/a", "a/", "a//b", "[", "[]", "[!]", "[a", "[z-a]", "a/[b", "[a/b]"} {
		if _, err := Compile(pat); err == nil {
			t.Errorf("Compile(%q) succeeded, want error", pat)
		}
	}
}

func TestLiteralPrefix(t *testing.T) {
	tests := map[string]string{
		"src/**/*.txt": "src/",
		"src/a.txt":    "src/a.txt",
		"**/x":         "",
		"src/ab*":      "src/ab",
		"lib/**":       "lib",
		"lib/**/**":    "lib",
		"lib/**/x":     "lib/",
	}
	for pat, want := range tests {
		p, err := Compile(pat)
		if err != nil {
			t.Fatal(err)
		}
		if got := p.LiteralPrefix(); got != want {
			t.Errorf("LiteralPrefix(%q) = %q, want %q", pat, got, want)
		}
	}
}
