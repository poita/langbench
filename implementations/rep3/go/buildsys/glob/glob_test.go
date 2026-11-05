package glob

import "testing"

func TestMatchTable(t *testing.T) {
	cases := []struct {
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
		{"*", []string{"", "a"}, []string{"a//b", "a/b"}},
		{"**", []string{"", "a", "a/b", "a//b", "/x"}, nil},
		{"[-a]", []string{"-", "a"}, []string{"b"}},
		{"[a-]", []string{"a", "-"}, []string{"b"}},
		{"[*?]", []string{"*", "?"}, []string{"a"}},
		{"a/**/**/b", []string{"a/b", "a/x/b", "a/x/y/b"}, []string{"a/x"}},
		{"**/**", []string{"a", "a/b"}, nil},
		{"x/*/y", []string{"x//y", "x/a/y"}, []string{"x/y"}},
		{"?", nil, []string{""}},
	}
	for _, c := range cases {
		p, err := Compile(c.pat)
		if err != nil {
			t.Fatalf("Compile(%q): %v", c.pat, err)
		}
		for _, s := range c.yes {
			if !p.Match(s) {
				t.Errorf("%q should match %q", c.pat, s)
			}
		}
		for _, s := range c.no {
			if p.Match(s) {
				t.Errorf("%q should not match %q", c.pat, s)
			}
		}
	}
}

func TestMalformed(t *testing.T) {
	for _, pat := range []string{"", "/a", "a/", "a//b", "[", "[]", "[!]", "[b-a]", "a[bc", "x/[!", "[a-"} {
		if _, err := Compile(pat); err == nil {
			t.Errorf("Compile(%q) should fail", pat)
		}
	}
	for _, pat := range []string{"[]]", "[a-z]", "[!a]", "[a-]"} {
		_, err := Compile(pat)
		if pat == "[]]" {
			// ']' directly after '[' closes an empty class.
			if err == nil {
				t.Errorf("Compile(%q) should fail", pat)
			}
			continue
		}
		if err != nil {
			t.Errorf("Compile(%q): %v", pat, err)
		}
	}
}

func TestPrefix(t *testing.T) {
	cases := map[string]string{
		"src/**/*.txt": "src",
		"a/b/c":        "a/b/c",
		"**/x":         "",
		"*/x":          "",
		"src/a*/b":     "src",
		"src/**":       "src",
	}
	for pat, want := range cases {
		p, err := Compile(pat)
		if err != nil {
			t.Fatal(err)
		}
		if p.Prefix() != want {
			t.Errorf("Prefix(%q) = %q, want %q", pat, p.Prefix(), want)
		}
	}
}

func TestNoAllocation(t *testing.T) {
	p, _ := Compile("src/**/t_*.txt")
	n := testing.AllocsPerRun(100, func() { p.Match("src/a/b/c/d/t_xyz.txt") })
	if n != 0 {
		t.Errorf("Match allocates %v times", n)
	}
}
