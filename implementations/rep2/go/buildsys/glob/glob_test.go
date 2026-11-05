package glob

import "testing"

func TestMatch(t *testing.T) {
	cases := []struct {
		pat, s string
		want   bool
	}{
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
		{"**/*.txt", "a/b/c.txt", true},
		{"**/*.txt", "a.text", false},
		{"src/**/t_*.txt", "src/t_1.txt", true},
		{"src/**/t_*.txt", "src/a/b/t_2.txt", true},
		{"src/**/t_*.txt", "src/t.txt", false},
		{"src/?.txt", "src/a.txt", true},
		{"src/?.txt", "src/ab.txt", false},
		{"src/[ab]*.txt", "src/a1.txt", true},
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
		{"*", "", true},
		{"*", "a//b", false},
		{"**", "a//b", true},
		{"?", "", false},
		{"**/**/x", "a/b/x", true},
		{"**/a/**/b/**", "x/a/y/z/b", true},
		{"**/a/**/b/**", "x/b/a", false},
		{"a*b*c", "aXbYbZc", true},
		{"a*b*c", "aXbYbZ", false},
	}
	for _, c := range cases {
		p, err := Compile(c.pat)
		if err != nil {
			t.Errorf("Compile(%q): %v", c.pat, err)
			continue
		}
		if got := p.Match(c.s); got != c.want {
			t.Errorf("%q ~ %q = %v, want %v", c.pat, c.s, got, c.want)
		}
	}
}

func TestMalformed(t *testing.T) {
	for _, pat := range []string{"", "/a", "a/", "a//b", "[", "[]", "[!]", "[a", "[b-a]", "a/[x", "[a/b]"} {
		if _, err := Compile(pat); err == nil {
			t.Errorf("Compile(%q) succeeded", pat)
		}
	}
}

func TestLiteralPrefix(t *testing.T) {
	cases := map[string]string{
		"src/*.txt": "src",
		"src/a/b":   "src/a/b",
		"src/**":    "src",
		"**/x":      "",
		"*/x":       "",
		"a/b?/c":    "a",
		"a/b/[x]":   "a/b",
		"plain.txt": "plain.txt",
		"a/b**/c":   "a",
	}
	for pat, want := range cases {
		p, err := Compile(pat)
		if err != nil {
			t.Fatal(err)
		}
		if got := p.LiteralPrefix(); got != want {
			t.Errorf("LiteralPrefix(%q) = %q, want %q", pat, got, want)
		}
	}
}

func TestManyDoubleStarsTerminate(t *testing.T) {
	p, _ := Compile("**/a/**/a/**/a/**/a/**/b")
	s := "a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a"
	if p.Match(s) {
		t.Error("unexpected match")
	}
}
