package regexvm

import (
	"reflect"
	"strings"
	"testing"
)

func find(t *testing.T, pat, subj string) []int {
	t.Helper()
	re, err := Compile(pat)
	if err != nil {
		t.Fatalf("Compile(%q): %v", pat, err)
	}
	return re.FindSubmatchIndex([]byte(subj))
}

func TestMatches(t *testing.T) {
	cases := []struct {
		pat, subj string
		want      []int // nil = no match
	}{
		// spec examples
		{"(a|ab)(c|bcd)(d*)", "abcd", []int{0, 4, 0, 1, 1, 4, 4, 4}},
		{"a*", "bbb", []int{0, 0}},
		{"^(a+)+$", "aaaa", []int{0, 4, 0, 4}},
		{"^(a+)+$", "aaab", nil},
		{"(a|(b))+", "ba", []int{0, 2, 1, 2, 0, 1}},
		{"(a|(b))+", "ab", []int{0, 2, 1, 2, 1, 2}},
		{`[^a-c]\d{2,3}x?`, "zz123xx", []int{1, 6}},
		{`[^a-c]\d{2,3}x?`, "abc9", nil},
		{"(a*)*b", "aab", []int{0, 3, 2, 2}},
		{"x$|^(y)?z", "xz", nil},
		{"x$|^(y)?z", "yz", []int{0, 2, 0, 1}},
		{"x$|^(y)?z", "zzz", []int{0, 1, -1, -1}},
		{"(a){0}b|(c)?(d)", "xb", []int{1, 2, -1, -1, -1, -1, -1, -1}},
		{"(a){0}b|(c)?(d)", "xcd", []int{1, 3, -1, -1, 1, 2, 2, 3}},
		// semantics
		{"a|ab", "ab", []int{0, 1}},
		{"(a*){3}", "", []int{0, 0, 0, 0}},
		{"a^b", "ab", nil},
		{"", "abc", []int{0, 0}},
		{"$", "abc", []int{3, 3}},
		{"(|a)+", "aaa", []int{0, 0, 0, 0}},
		{"(a|b)*c", "abac", []int{0, 4, 2, 3}},
		{"a{2,3}", "aaaa", []int{0, 3}},
		{"a{2,}", "aaaa", []int{0, 4}},
		{"a{2}", "a", nil},
		{"a{0}", "a", []int{0, 0}},
		{"(ab){2,3}c", "ababababc", []int{2, 9, 6, 8}},
		{"(a?)?b", "b", []int{0, 1, 0, 0}},
		{".*x", "abxcx", []int{0, 5}},
		{`\w+@\w+`, "a b@c", []int{2, 5}},
		{`\D\S\W`, "1xy!", []int{1, 4}},
		{`[\d-]+`, "ab12-3c", []int{2, 6}},
		{`[a\-c]+`, "xa-cb", []int{1, 4}},
		{`\.\*\ `, "a.* b", []int{1, 4}},
		{"[^^]", "^a", []int{1, 2}},
		{"(a)|b", "b", []int{0, 1, -1, -1}},
		{"((a)|(b))+", "ab", []int{0, 2, 1, 2, 0, 1, 1, 2}},
		{"(a*)+", "b", []int{0, 0, 0, 0}},
	}
	for _, c := range cases {
		if got := find(t, c.pat, c.subj); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%q on %q = %v, want %v", c.pat, c.subj, got, c.want)
		}
	}
}

func TestLongSubjectNoRecursion(t *testing.T) {
	subj := strings.Repeat("a", 200000)
	if got := find(t, "^.*b", subj); got != nil {
		t.Errorf("got %v", got)
	}
	if got := find(t, "(a|b)*$", subj); got == nil || got[1] != len(subj) {
		t.Errorf("got %v", got)
	}
}

func TestPathological(t *testing.T) {
	if got := find(t, "(a*)*b", strings.Repeat("a", 18)); got != nil {
		t.Errorf("got %v", got)
	}
}

func TestMatcherReuse(t *testing.T) {
	var m Matcher
	m.Reset(MustCompile("(a)(b)?"))
	if !m.Match([]byte("xa")) || m.Start() != 1 || m.End() != 2 {
		t.Fatal("first match wrong")
	}
	if s, e, ok := m.Group(1); !ok || s != 1 || e != 2 {
		t.Errorf("group 1 = %d,%d,%v", s, e, ok)
	}
	if _, _, ok := m.Group(2); ok {
		t.Error("group 2 should be unset")
	}
	if _, _, ok := m.Group(3); ok {
		t.Error("group 3 out of range")
	}
	m.Reset(MustCompile("z"))
	if m.Match([]byte("abc")) {
		t.Error("unexpected match")
	}
	if _, _, ok := m.Group(1); ok {
		t.Error("no match: group must be unavailable")
	}
}

func TestMatchString(t *testing.T) {
	re := MustCompile(`^\d+$`)
	if !re.MatchString("123") || re.MatchString("12a") {
		t.Error("MatchString wrong")
	}
	if re.String() != `^\d+$` {
		t.Error("String wrong")
	}
}
