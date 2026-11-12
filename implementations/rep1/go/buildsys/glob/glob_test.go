package glob

import "testing"

func TestMatch(t *testing.T) {
	tests := []struct {
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
		{"src/**", "srcx", false},
		{"src/**", "other/a.txt", false},
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
		{"[-a]*", "-x", true},
		{"[a-]*", "-x", true},
		{"[*?]", "*", true},
		{"*", "", true},
		{"?", "", false},
		{"**", "", true},
		{"*", "a//b", false},
		{"**", "a//b", true},
		{"**/**", "a", true},
		{"a/**/**/c", "a/c", true},
		{"a/**/b/**/c", "a/x/b/y/z/c", true},
		{"a/**/b/**/c", "a/x/c", false},
		{"*a*b*", "xaxbx", true},
		{"*a*b*", "xbxax", false},
	}
	for _, tc := range tests {
		p, err := Compile(tc.pat)
		if err != nil {
			t.Fatalf("Compile(%q): %v", tc.pat, err)
		}
		if got := p.Match(tc.s); got != tc.want {
			t.Errorf("%q ~ %q = %v, want %v", tc.pat, tc.s, got, tc.want)
		}
	}
}

func TestMalformed(t *testing.T) {
	for _, pat := range []string{"", "/a", "a/", "a//b", "[", "[a", "[]", "[!]", "[z-a]", "a[b", "[a-]]x/"} {
		if _, err := Compile(pat); err == nil {
			t.Errorf("Compile(%q) succeeded, want error", pat)
		}
	}
	for _, pat := range []string{"[a-]", "[-a]", "[]-]", "[!a]"} {
		_, err := Compile(pat)
		if pat == "[]-]" {
			// "]" ends the class immediately with no items: malformed.
			if err == nil {
				t.Errorf("Compile(%q) succeeded, want error", pat)
			}
			continue
		}
		if err != nil {
			t.Errorf("Compile(%q): %v", pat, err)
		}
	}
}

func TestLiteralPrefix(t *testing.T) {
	tests := map[string]string{
		"src/**/*.txt": "src",
		"lib/**":       "lib",
		"src/a*":       "src/a",
		"plain":        "plain",
		"**":           "",
	}
	for pat, want := range tests {
		if got := LiteralPrefix(pat); got != want {
			t.Errorf("LiteralPrefix(%q) = %q, want %q", pat, got, want)
		}
	}
}
