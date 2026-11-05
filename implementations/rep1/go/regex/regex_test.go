package regex_test

import (
	"errors"
	"reflect"
	"strings"
	"testing"

	"example.com/regex"
)

func TestFindStringSubmatchIndex(t *testing.T) {
	tests := []struct {
		pattern, subject string
		want             []int // nil: no match
	}{
		// Worked examples from the specification.
		{`(a|ab)(c|bcd)(d*)`, "abcd", []int{0, 4, 0, 1, 1, 4, 4, 4}},
		{`a*`, "bbb", []int{0, 0}},
		{`a*`, "", []int{0, 0}},
		{`^(a+)+$`, "aaaa", []int{0, 4, 0, 4}},
		{`^(a+)+$`, "aaab", nil},
		{`(a|(b))+`, "ba", []int{0, 2, 1, 2, 0, 1}},
		{`(a|(b))+`, "ab", []int{0, 2, 1, 2, 1, 2}},
		{`[^a-c]\d{2,3}x?`, "zz123xx", []int{1, 6}},
		{`[^a-c]\d{2,3}x?`, "abc9", nil},
		{`(a*)*b`, "aab", []int{0, 3, 2, 2}},
		{`(a*)*b`, "ccc", nil},
		{`x$|^(y)?z`, "xz", nil},
		{`x$|^(y)?z`, "yz", []int{0, 2, 0, 1}},
		{`x$|^(y)?z`, "zzz", []int{0, 1, -1, -1}},
		{`(a){0}b|(c)?(d)`, "xb", []int{1, 2, -1, -1, -1, -1, -1, -1}},
		{`(a){0}b|(c)?(d)`, "xcd", []int{1, 3, -1, -1, 1, 2, 2, 3}},
		{`(a){0}b|(c)?(d)`, "d", []int{0, 1, -1, -1, -1, -1, 0, 1}},

		// Semantics.
		{`a|ab`, "ab", []int{0, 1}},
		{`(a*){3}`, "", []int{0, 0, 0, 0}},
		{`a^b`, "ab", nil},
		{`$`, "abc", []int{3, 3}},
		{`^$`, "", []int{0, 0}},
		{`a||b`, "b", []int{0, 0}},
		{`(|b)c`, "bc", []int{0, 2, 0, 1}},
		{`.*`, "abc", []int{0, 3}},
		{`a{2,3}`, "aaaa", []int{0, 3}},
		{`a{2,}`, "aaaa", []int{0, 4}},
		{`a{0}`, "a", []int{0, 0}},
		{`\w+@\w+`, "mail bob@host now", []int{5, 13}},
		{`[a\-z]+`, "x-az", []int{1, 4}},
		{`[-a]+`, "-a-", []int{0, 3}},
		{`[a-]+`, "a-a", []int{0, 3}},
		{`[\]\[]+`, "x][", []int{1, 3}},
		{`\D\S\W`, "a b", nil},
		{`\.\*\ `, ".* ", []int{0, 3}},
		{`(a)|b`, "b", []int{0, 1, -1, -1}},
		{`(a?)*`, "aa", []int{0, 2, 2, 2}},
		{`((a)|b)*`, "ab", []int{0, 2, 1, 2, 0, 1}},
	}
	for _, tc := range tests {
		re, err := regex.Compile(tc.pattern)
		if err != nil {
			t.Errorf("Compile(%q): %v", tc.pattern, err)
			continue
		}
		got := re.FindStringSubmatchIndex(tc.subject)
		if !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%q on %q = %v, want %v", tc.pattern, tc.subject, got, tc.want)
		}
	}
}

func TestNumGroupsAndString(t *testing.T) {
	re := regex.MustCompile(`(a)(b(c))()`)
	if re.NumGroups() != 4 {
		t.Errorf("NumGroups = %d, want 4", re.NumGroups())
	}
	if re.String() != `(a)(b(c))()` {
		t.Errorf("String = %q", re.String())
	}
}

func TestMatchString(t *testing.T) {
	re := regex.MustCompile(`b+c`)
	if !re.MatchString("abbc") || re.MatchString("ac") {
		t.Error("MatchString gave the wrong answer")
	}
}

func TestMatcherReuse(t *testing.T) {
	var m regex.Matcher
	a, b := regex.MustCompile(`(x)+`), regex.MustCompile(`(y)(z)?`)
	m.Reset(a)
	if !m.Find([]byte("axx")) {
		t.Fatal("expected a match")
	}
	if s, e := m.Span(); s != 1 || e != 3 {
		t.Errorf("span = %d,%d", s, e)
	}
	if gs, ge, ok := m.Group(1); !ok || gs != 2 || ge != 3 {
		t.Errorf("group 1 = %d,%d,%v", gs, ge, ok)
	}
	m.Reset(b)
	if !m.Find([]byte("y")) {
		t.Fatal("expected a match")
	}
	if _, _, ok := m.Group(2); ok {
		t.Error("group 2 should be unset")
	}
	if m.Find([]byte("q")) {
		t.Error("unexpected match")
	}
}

func TestDeepSubjects(t *testing.T) {
	long := strings.Repeat("a", 10000)
	if got := regex.MustCompile(`.*`).FindStringSubmatchIndex(long); !reflect.DeepEqual(got, []int{0, 10000}) {
		t.Errorf(".* = %v", got)
	}
	if got := regex.MustCompile(`(a)*$`).FindStringSubmatchIndex(long); !reflect.DeepEqual(got, []int{0, 10000, 9999, 10000}) {
		t.Errorf("(a)*$ = %v", got)
	}
	if regex.MustCompile(`(a*)*b`).MatchString(strings.Repeat("a", 18)) {
		t.Error("unexpected match")
	}
}

func TestCompileErrors(t *testing.T) {
	for _, p := range []string{
		`(`, `)`, `a)`, `(a`, `[a`, `[]`, `[]a]`, `*a`, `a**`, `a+*`, `^*`, `$+`, `(*)`, `|*`,
		`a{`, `a{1`, `a{1,`, `a{,2}`, `a{3,2}`, `a{x}`, `{1}`, `}`, `]`, `\`, `\b`, `\1`, `[\b]`,
		`[z-a]`, `[a-\d]`, `a{99999}`,
	} {
		_, err := regex.Compile(p)
		var se *regex.SyntaxError
		if !errors.As(err, &se) {
			t.Errorf("Compile(%q) error = %v, want *SyntaxError", p, err)
		}
	}
}

func TestProgramTooLarge(t *testing.T) {
	_, err := regex.Compile(`(((a|b){1000}){1000}){1000}`)
	var le *regex.LimitError
	if !errors.As(err, &le) {
		t.Errorf("error = %v, want *LimitError", err)
	}
}
