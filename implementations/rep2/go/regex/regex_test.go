package regex

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

// format renders a match the way the command-line tool does.
func format(m *Match) string {
	if m == nil {
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

type matchCase struct{ pattern, subject, want string }

var matchCases = []matchCase{
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
	{`(a+)(a*)`, "aaa", "match 0 3|0,3|3,3"},
	{`a{2,3}`, "aaaa", "match 0 3"},
	{`a{2,}`, "aaaa", "match 0 4"},
	{`a{2}`, "a", "no"},
	{`(a|b){3}`, "abab", "match 0 3|2,3"},

	// Empty iterations.
	{`(a*){3}`, "", "match 0 0|0,0"},
	{`(a*)+`, "b", "match 0 0|0,0"},
	{`(a|)+b`, "aab", "match 0 3|2,2"},
	{`(){2,5}x`, "x", "match 0 1|0,0"},
	{`(a*)?`, "aa", "match 0 2|0,2"},

	// Captures keep values from earlier iterations; abandoned ones vanish.
	{`((a)|(b))*`, "ab", "match 0 2|1,2|0,1|1,2"},
	{`(a)|b`, "b", "match 0 1|-"},
	{`(a)*b`, "aab", "match 0 3|1,2"},
	{`((a)b|ac)`, "ac", "match 0 2|0,2|-"},

	// Anchors.
	{`a^b`, "ab", "no"},
	{`^`, "abc", "match 0 0"},
	{`$`, "abc", "match 3 3"},
	{`b$`, "abb", "match 2 3"},
	{`^$`, "", "match 0 0"},
	{`^$`, "a", "no"},
	{`(^a|b)`, "ba", "match 0 1|0,1"},
	{`(^|x)a`, "ba", "no"},

	// Classes and escapes.
	{`\w+`, "  foo_9 ", "match 2 7"},
	{`\s`, "ab c", "match 2 3"},
	{`\S+`, "  ab ", "match 2 4"},
	{`\D\d`, "12a3", "match 2 4"},
	{`\W`, "ab-c", "match 2 3"},
	{`[a-c-]+`, "x-ab-y", "match 1 5"},
	{`[\d\s]+`, "ab 12 cd", "match 2 6"},
	{`[^\d]+`, "12ab3", "match 2 4"},
	{`\.\*\(\)`, "a.*()", "match 1 5"},
	{`\ \@`, "x @", "match 1 3"},
	{`.`, "", "no"},
	{`a.c`, "abc", "match 0 3"},

	// Start-position search.
	{`ab`, "xxab", "match 2 4"},
	{`b|c`, "aac", "match 2 3"},
	{`x*`, "aaxx", "match 0 0"},
	{`a|^b`, "cb", "no"},
	{`$|a`, "b", "match 1 1"},
}

func TestFind(t *testing.T) {
	for _, tc := range matchCases {
		re, err := Compile(tc.pattern)
		if err != nil {
			if tc.want != "no" {
				t.Errorf("Compile(%q): %v", tc.pattern, err)
			}
			continue
		}
		if got := format(re.Find(tc.subject)); got != tc.want {
			t.Errorf("%q on %q = %s, want %s", tc.pattern, tc.subject, got, tc.want)
		}
		if got := format(re.FindBytes([]byte(tc.subject))); got != tc.want {
			t.Errorf("FindBytes %q on %q = %s, want %s", tc.pattern, tc.subject, got, tc.want)
		}
	}
}

func TestCompileErrors(t *testing.T) {
	for _, p := range []string{"a*?", "(?:a)", "(a", "[b-a]", `\q`, "a{2,1}"} {
		if _, err := Compile(p); err == nil {
			t.Errorf("Compile(%q) succeeded, want error", p)
		}
	}
}

func TestTooLarge(t *testing.T) {
	_, err := Compile(`((((a{100}){100}){100}){100}){100}`)
	if !errors.Is(err, ErrTooLarge) {
		t.Errorf("err = %v, want ErrTooLarge", err)
	}
}

func TestAccessors(t *testing.T) {
	re := MustCompile(`(a)(b)|c`)
	if re.NumGroups() != 2 || re.String() != `(a)(b)|c` {
		t.Errorf("NumGroups/String wrong: %d %q", re.NumGroups(), re)
	}
	if !re.MatchString("zzc") || re.MatchString("zzz") {
		t.Error("MatchString wrong")
	}
}

func TestMustCompilePanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("MustCompile did not panic")
		}
	}()
	MustCompile("(")
}

func TestFindIndexReusesBuffer(t *testing.T) {
	re := MustCompile(`(a)|(b)`)
	buf := make([]int, 0, 8)
	loc, ok := re.FindIndex("xb", buf)
	if !ok || fmt.Sprint(loc) != "[1 2 -1 -1 1 2]" {
		t.Errorf("loc = %v, ok = %v", loc, ok)
	}
	if &loc[0] != &buf[:1][0] {
		t.Error("FindIndex did not reuse dst")
	}
	// State from the previous call must not leak into the next.
	loc, _ = re.FindIndex("a", loc)
	if fmt.Sprint(loc) != "[0 1 0 1 -1 -1]" {
		t.Errorf("second loc = %v", loc)
	}
}

func TestDeepBacktracking(t *testing.T) {
	re := MustCompile(`^(.*)(x?)$`)
	s := strings.Repeat("a", 200000)
	m := re.Find(s)
	if m == nil || m.End != len(s) || m.Groups[0].End != len(s) {
		t.Fatalf("unexpected match %v", format(m))
	}
	// Forces the whole run of .* to be given back one byte at a time.
	if m := MustCompile(`.*b`).Find(s[:3000]); m != nil {
		t.Fatal("unexpected match")
	}
}

func TestPathological(t *testing.T) {
	cases := []struct{ pattern, subject string }{
		{`(a*)*b`, strings.Repeat("a", 18)},
		{`(x+x+)+y`, strings.Repeat("x", 18)},
		{`(a|aa)+c`, strings.Repeat("a", 24)},
	}
	for _, tc := range cases {
		if MustCompile(tc.pattern).MatchString(tc.subject) {
			t.Errorf("%q unexpectedly matched", tc.pattern)
		}
	}
}

func TestConcurrentUse(t *testing.T) {
	re := MustCompile(`(\d+)-(\d+)`)
	done := make(chan string, 8)
	for i := 0; i < 8; i++ {
		go func() { done <- format(re.Find("ab 12-345 cd")) }()
	}
	for i := 0; i < 8; i++ {
		if got := <-done; got != "match 3 9|3,5|6,9" {
			t.Errorf("got %s", got)
		}
	}
}

func ExampleRegexp_Find() {
	re := MustCompile(`(\w+)@(\w+)\.com`)
	m := re.Find("mail bob@example.com now")
	fmt.Println(m.Start, m.End, m.Groups[0], m.Groups[1])
	// Output: 5 20 {5 8} {9 16}
}

func ExampleRegexp_FindIndex() {
	re := MustCompile(`(a|(b))+`)
	loc, ok := re.FindIndex("ba", nil)
	fmt.Println(loc, ok)
	// Output: [0 2 1 2 0 1] true
}
