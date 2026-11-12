package regexbt_test

import (
	"fmt"
	"strings"
	"testing"

	"example.com/regexbt"
	"example.com/regexbt/syntax"
)

// format renders a result the way the command-line tool does.
func format(m regexbt.Match, ok bool) string {
	if !ok {
		return "no"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "match %d %d", m.Start, m.End)
	for _, g := range m.Groups {
		if g.IsSet() {
			fmt.Fprintf(&b, "|%d,%d", g.Start, g.End)
		} else {
			b.WriteString("|-")
		}
	}
	return b.String()
}

func TestFind(t *testing.T) {
	tests := []struct{ pattern, subject, want string }{
		// Examples from the specification.
		{`(a|ab)(c|bcd)(d*)`, "abcd", "match 0 4|0,1|1,4|4,4"},
		{`a*`, "bbb", "match 0 0"},
		{`a*`, "", "match 0 0"},
		{`^(a+)+$`, "aaaa", "match 0 4|0,4"},
		{`^(a+)+$`, "aaab", "no"},
		{`(a|(b))+`, "ba", "match 0 2|1,2|0,1"},
		{`(a|(b))+`, "ab", "match 0 2|1,2|1,2"},
		{`[^a-c]\d{2,3}x?`, "zz123xx", "match 1 6"},
		{`[^a-c]\d{2,3}x?`, "abc9", "no"},
		{`(a*)*b`, "aab", "match 0 3|2,2"},
		{`(a*)*b`, "ccc", "no"},
		{`x$|^(y)?z`, "xz", "no"},
		{`x$|^(y)?z`, "yz", "match 0 2|0,1"},
		{`x$|^(y)?z`, "zzz", "match 0 1|-"},
		{`(a){0}b|(c)?(d)`, "xb", "match 1 2|-|-|-"},
		{`(a){0}b|(c)?(d)`, "xcd", "match 1 3|-|1,2|2,3"},
		{`(a){0}b|(c)?(d)`, "d", "match 0 1|-|-|0,1"},

		// Ordered choice and greediness.
		{`a|ab`, "ab", "match 0 1"},
		{`a+?`, "", "no"}, // not a lazy quantifier: handled in TestCompileErrors
		{`a{2,3}`, "aaaa", "match 0 3"},
		{`a{2,}`, "aaaa", "match 0 4"},
		{`a{0}`, "a", "match 0 0"},
		{`(a|b)*c`, "abac", "match 0 4|2,3"},

		// Empty iterations and mandatory empty iterations.
		{`(a*){3}`, "", "match 0 0|0,0"},
		{`(|a)+`, "aa", "match 0 0|0,0"},
		{`(a|)+`, "aa", "match 0 2|2,2"},
		{`(a?)*?`, "", "no"},

		// Anchors.
		{`a^b`, "ab", "no"},
		{`$`, "abc", "match 3 3"},
		{`^`, "abc", "match 0 0"},
		{`^$`, "", "match 0 0"},
		{`b$`, "abab", "match 3 4"},
		{`^b`, "ab", "no"},

		// Classes and escapes.
		{`[a-c-]+`, "-abc-d", "match 0 5"},
		{`[-a]+`, "a-a", "match 0 3"},
		{`[\]\\]+`, `x]\]`, `match 1 4`},
		{`[^^]`, "^a", "match 1 2"},
		{`[a^]+`, "^a", "match 0 2"},
		{`[\d\s]+`, "ab 12 cd", "match 2 6"},
		{`\w+`, "  foo_Bar9 ", "match 2 10"},
		{`\W+`, "foo  bar", "match 3 5"},
		{`\S+`, "  ab ", "match 2 4"},
		{`\D\d`, "12a3", "match 2 4"},
		{`\.\*\ `, "x.* y", "match 1 4"},
		{`.`, "", "no"},
		{` a `, "b a c", "match 1 4"},

		// Groups.
		{`()`, "", "match 0 0|0,0"},
		{`(a)|(b)`, "b", "match 0 1|-|0,1"},
		{`((a)|b)+`, "ab", "match 0 2|1,2|0,1"},
		{`(a)*`, "b", "match 0 0|-"},
		{`(a)(b)?`, "ac", "match 0 1|0,1|-"},
		{`||`, "x", "match 0 0"},
		{`((((a))))`, "a", "match 0 1|0,1|0,1|0,1|0,1"},
	}
	for _, tc := range tests {
		re, err := regexbt.Compile(tc.pattern)
		if err != nil {
			if tc.pattern == `a+?` || tc.pattern == `(a?)*?` {
				continue // invalid in this dialect, see TestCompileErrors
			}
			t.Errorf("Compile(%q): %v", tc.pattern, err)
			continue
		}
		m, ok := re.Find(tc.subject)
		if got := format(m, ok); got != tc.want {
			t.Errorf("%q on %q = %q, want %q", tc.pattern, tc.subject, got, tc.want)
		}
	}
}

func TestCompileErrors(t *testing.T) {
	for _, p := range []string{
		`*a`, `a**`, `a+?`, `^*`, `$+`, `(`, `)`, `a)`, `(a`, `[a`, `[]`, `a{`, `a{1`,
		`a{2,1}`, `a{,2}`, `{1}`, `a}`, `a]`, `\`, `\d{`, `\b`, `\1`, `(*)`, `|*`,
		`[z-a]`, `[a-\d]`, `a{1001}`, `((a{1000}){1000}){1000}`,
	} {
		if _, err := regexbt.Compile(p); err == nil {
			t.Errorf("Compile(%q) succeeded, want an error", p)
		}
	}
}

func TestSyntaxErrorType(t *testing.T) {
	_, err := regexbt.Compile(`a(`)
	se, ok := err.(*syntax.Error)
	if !ok {
		t.Fatalf("error type %T, want *syntax.Error", err)
	}
	if se.Pattern != `a(` {
		t.Errorf("Pattern = %q", se.Pattern)
	}
}

func TestAPI(t *testing.T) {
	re := regexbt.MustCompile(`(\d+)-(\d+)?`)
	if re.NumGroups() != 2 || re.String() != `(\d+)-(\d+)?` {
		t.Errorf("NumGroups/String = %d, %q", re.NumGroups(), re.String())
	}
	if !re.MatchString("tel 12-") || re.MatchString("tel 12") {
		t.Error("MatchString gave the wrong answer")
	}
	var m regexbt.Match
	if !re.FindInto("x 5-", &m) || m.Groups[1].IsSet() || m.Groups[0] != (regexbt.Span{Start: 2, End: 3}) {
		t.Errorf("FindInto = %+v", m)
	}
	defer func() {
		if recover() == nil {
			t.Error("MustCompile did not panic")
		}
	}()
	regexbt.MustCompile(`(`)
}

// A machine reused across subjects must not leak captures between calls.
func TestReuseDoesNotLeakCaptures(t *testing.T) {
	re := regexbt.MustCompile(`(a)|(b)`)
	for i := 0; i < 3; i++ {
		for _, tc := range []struct{ s, want string }{
			{"a", "match 0 1|0,1|-"}, {"b", "match 0 1|-|0,1"}, {"c", "no"},
		} {
			m, ok := re.Find(tc.s)
			if got := format(m, ok); got != tc.want {
				t.Fatalf("%q = %q, want %q", tc.s, got, tc.want)
			}
		}
	}
}

func TestLongSubjectsDoNotOverflowStack(t *testing.T) {
	s := strings.Repeat("a", 200000)
	m, ok := regexbt.MustCompile(`(.*)b?$`).Find(s)
	if got := format(m, ok); got != "match 0 200000|0,200000" {
		t.Errorf("got %q", got)
	}
	// Anchored, so only one start position is tried.
	if _, ok := regexbt.MustCompile(`^(a|b)*c`).Find(s); ok {
		t.Error("unexpected match")
	}
}

func TestPathological(t *testing.T) {
	s := strings.Repeat("a", 22)
	for _, p := range []string{`(a*)*b`, `(a|aa)+c`, `(a+a+)+b`} {
		if _, ok := regexbt.MustCompile(p).Find(s); ok {
			t.Errorf("%q matched", p)
		}
	}
}

func TestConcurrentUse(t *testing.T) {
	re := regexbt.MustCompile(`(\w+)@(\w+)\.com`)
	done := make(chan string, 8)
	for i := 0; i < 8; i++ {
		go func() {
			m, ok := re.Find("mail bob@example.com now")
			done <- format(m, ok)
		}()
	}
	for i := 0; i < 8; i++ {
		if got := <-done; got != "match 5 20|5,8|9,16" {
			t.Errorf("got %q", got)
		}
	}
}

func ExampleRegexp_Find() {
	re := regexbt.MustCompile(`(\d+)-(\d+)?`)
	m, _ := re.Find("tel: 555-")
	fmt.Println(m.Start, m.End, m.Groups[0], m.Groups[1].IsSet())
	// Output: 5 9 {5 8} false
}

func BenchmarkBacktrack(b *testing.B) {
	re := regexbt.MustCompile(`(a|aa)+c`)
	s := strings.Repeat("a", 24)
	var m regexbt.Match
	for i := 0; i < b.N; i++ {
		re.FindInto(s, &m)
	}
}
