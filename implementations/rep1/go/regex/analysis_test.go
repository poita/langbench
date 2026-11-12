package regexbt

import (
	"testing"

	"example.com/regexbt/syntax"
)

func TestAnalysis(t *testing.T) {
	for _, tc := range []struct {
		pat      string
		first    string
		nullable bool
		anchored bool
	}{
		{`abc`, "a", false, false},
		{`a*b`, "ab", false, false},
		{`a*`, "a", true, false},
		{`(a|b)c`, "ab", false, false},
		{`^a`, "a", false, true},
		{`(^a|^b)`, "ab", false, true},
		{`(^a|b)`, "ab", false, false},
		{`(^a)*`, "a", true, false},
		{`x{0}y`, "y", false, false},
		{`$`, "", true, false},
	} {
		tree, _, err := syntax.Parse(tc.pat)
		if err != nil {
			t.Fatal(err)
		}
		set, nullable := firstSet(tree)
		var want syntax.CharSet
		for _, c := range []byte(tc.first) {
			want.Add(c)
		}
		if set != want || nullable != tc.nullable || startsWithBol(tree) != tc.anchored {
			t.Errorf("%q: nullable=%v anchored=%v first-match=%v", tc.pat, nullable, startsWithBol(tree), set == want)
		}
	}
}
