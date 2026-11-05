package regex_test

import (
	"fmt"
	"strings"
	"testing"

	"regex"
)

func format(re *regex.Regexp, s string) string {
	loc := re.FindStringSubmatchIndex(s)
	if loc == nil {
		return "no"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "match %d %d", loc[0], loc[1])
	for g := 1; g <= re.NumGroups(); g++ {
		if loc[2*g] < 0 {
			b.WriteString("|-")
		} else {
			fmt.Fprintf(&b, "|%d,%d", loc[2*g], loc[2*g+1])
		}
	}
	return b.String()
}

func TestMatch(t *testing.T) {
	tests := []struct{ pat, subj, want string }{
		// Examples from the specification.
		{`(a|ab)(c|bcd)(d*)`, "abcd", "match 0 4|0,1|1,4|4,4"},
		{`a*`, "bbb", "match 0 0"},
		{`^(a+)+$`, "aaaa", "match 0 4|0,4"},
		{`^(a+)+$`, "aaab", "no"},
		{`(a|(b))+`, "ba", "match 0 2|1,2|0,1"},
		{`(a|(b))+`, "ab", "match 0 2|1,2|1,2"},
		{`[^a-c]\d{2,3}x?`, "zz123xx", "match 1 6"},
		{`[^a-c]\d{2,3}x?`, "abc9", "no"},
		{`(a*)*b`, "aab", "match 0 3|2,2"},
		{`x$|^(y)?z`, "xz", "no"},
		{`x$|^(y)?z`, "yz", "match 0 2|0,1"},
		{`x$|^(y)?z`, "zzz", "match 0 1|-"},
		{`(a){0}b|(c)?(d)`, "xb", "match 1 2|-|-|-"},
		{`(a){0}b|(c)?(d)`, "xcd", "match 1 3|-|1,2|2,3"},
		{`(a){0}b|(c)?(d)`, "d", "match 0 1|-|-|0,1"},
		// Semantics.
		{`a|ab`, "ab", "match 0 1"},
		{`(a*){3}`, "", "match 0 0|0,0"},
		{`(a*)+`, "b", "match 0 0|0,0"},
		{`(|a)+`, "aa", "match 0 0|0,0"},
		{`a^b`, "ab", "no"},
		{`^`, "abc", "match 0 0"},
		{`$`, "abc", "match 3 3"},
		{``, "abc", "match 0 0"},
		{`a{0}`, "a", "match 0 0"},
		{`a{2,}`, "aaaa", "match 0 4"},
		{`a{2,3}`, "aaaa", "match 0 3"},
		{`(ab){2}`, "ababab", "match 0 4|2,4"},
		{`(a|b)*c`, "abac", "match 0 4|2,3"},
		{`a.c`, "a c", "match 0 3"},
		{`  x `, "a  x ", "match 1 5"},
		// Classes and escapes.
		{`[a-c]+`, "xabcx", "match 1 4"},
		{`[-a]+`, "x-a-", "match 1 4"},
		{`[a-]+`, "x-a-", "match 1 4"},
		{`[\]\-x]+`, "a]-x", "match 1 4"},
		{`[^\d\s]+`, "12 ab3", "match 3 5"},
		{`[\w.]+`, "-a_b.c-", "match 1 6"},
		{`[--/]+`, "a-./b", "match 1 4"},
		{`\D+`, "12ab34", "match 2 4"},
		{`\W\S`, "a b", "match 1 3"},
		{`\.\*\(\)\[\]\{\}\|\+\?\^\$\\\ \@`, `.*()[]{}|+?^$\ @`, "match 0 16"},
		{`^[^^]`, "^a", "no"},
		{`[a^]+`, "^a", "match 0 2"},
	}
	for _, tc := range tests {
		re, err := regex.Compile(tc.pat)
		if err != nil {
			t.Errorf("Compile(%q): %v", tc.pat, err)
			continue
		}
		if got := format(re, tc.subj); got != tc.want {
			t.Errorf("%q on %q = %q, want %q", tc.pat, tc.subj, got, tc.want)
		}
	}
}

func TestCompileErrors(t *testing.T) {
	for _, pat := range []string{`(`, `)`, `a**`, `*a`, `+`, `[a`, `[b-a]`, `a{2,1}`, `a{`, `\q`, `a\`, `^*`, `a{1}{2}`, `(?`, `a{99999}`} {
		if _, err := regex.Compile(pat); err == nil {
			t.Errorf("Compile(%q) succeeded, want error", pat)
		}
	}
}

func TestMustCompilePanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("MustCompile did not panic on an invalid pattern")
		}
	}()
	regex.MustCompile(`(`)
}

func TestDeepSubject(t *testing.T) {
	// Recursion depth must not grow with the subject.
	s := strings.Repeat("a", 200000)
	if got := format(regex.MustCompile(`(a|b)*$`), s); got != "match 0 200000|199999,200000" {
		t.Errorf("got %q", got)
	}
	if got := format(regex.MustCompile(`.*x`), s[:3000]); got != "no" {
		t.Errorf("got %q", got)
	}
}

func TestMatcherReuse(t *testing.T) {
	re := regex.MustCompile(`(a)|(b)`)
	m := re.NewMatcher()
	if !m.Find([]byte("xa")) {
		t.Fatal("no match on xa")
	}
	if s, e, ok := m.Group(1); !ok || s != 1 || e != 2 {
		t.Errorf("group 1 = %d,%d,%v", s, e, ok)
	}
	if !m.Find([]byte("b")) {
		t.Fatal("no match on b")
	}
	if _, _, ok := m.Group(1); ok {
		t.Error("group 1 should be unset after reuse")
	}
	if s, e, ok := m.Group(2); !ok || s != 0 || e != 1 {
		t.Errorf("group 2 = %d,%d,%v", s, e, ok)
	}
	if m.Find([]byte("zzz")) {
		t.Error("unexpected match on zzz")
	}
	if _, _, ok := m.Group(3); ok {
		t.Error("out-of-range group reported as set")
	}
}

func TestMatchString(t *testing.T) {
	re := regex.MustCompile(`^\d+$`)
	if !re.MatchString("123") || re.MatchString("12a") {
		t.Error("MatchString gave the wrong answer")
	}
	if re.String() != `^\d+$` {
		t.Errorf("String() = %q", re.String())
	}
}

func BenchmarkPathological(b *testing.B) {
	re := regex.MustCompile(`(x+x+)+y`)
	m := re.NewMatcher()
	s := []byte(strings.Repeat("x", 18))
	for i := 0; i < b.N; i++ {
		m.Find(s)
	}
}
