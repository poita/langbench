package query

import (
	"reflect"
	"testing"

	"fulltext/analysis"
)

func TestParse(t *testing.T) {
	tests := []struct{ in, want string }{
		{"cat", "(cat)"},
		{"cat dog", "[(cat) AND (dog)]"},
		{"cat AND dog", "[(cat) AND (dog)]"},
		{"cat OR dog", "[(cat) OR (dog)]"},
		{"cat dog OR bird", "[[(cat) AND (dog)] OR (bird)]"},
		{"cat OR dog bird", "[(cat) OR [(dog) AND (bird)]]"},
		{"NOT cat", "NOT (cat)"},
		{"cat NOT dog", "[(cat) AND NOT (dog)]"},
		{"NOT NOT cat", "NOT NOT (cat)"},
		{"(cat OR dog) bird", "[[(cat) OR (dog)] AND (bird)]"},
		{`"quick brown" fox`, "[(quick brown) AND (fox)]"},
		{"well-known", "(well known)"},
		{`"to be or not to be"`, "(to be or not to be)"},
		{"running", "(run)"},
		// Everything that parses to the empty tree.
		{"()", "<empty>"}, {"the", "<empty>"}, {"NOT", "<empty>"}, {"", "<empty>"},
		{`""`, "<empty>"}, {"...", "<empty>"}, {"AND", "<empty>"}, {"The", "<empty>"},
		// Recovery cases from the specification.
		{"cat AND", "(cat)"}, {"OR cat", "(cat)"}, {"cat ()", "(cat)"},
		{"cat NOT ()", "(cat)"}, {"cat NOT (", "(cat)"}, {"(cat", "(cat)"},
		{`"cat`, "(cat)"}, {"cat ) dog", "(cat)"}, {"cat ) ) dog", "(cat)"},
		{"cat OR AND dog", "[(cat) OR (dog)]"}, {"cat AND OR dog", "[(cat) OR (dog)]"},
		{"cat AND AND dog", "[(cat) AND (dog)]"},
		{"dog NOT ( cat", "[(dog) AND NOT (cat)]"},
		{"cat NOT OR dog", "[(cat) AND (dog)]"}, // OR after NOT is consumed as the operand
		{"and", "<empty>"}, {"cat and dog", "[(cat) AND (dog)]"},
		{`cat"dog"`, "[(cat) AND (dog)]"},
	}
	a := analysis.NewAnalyzer()
	for _, tc := range tests {
		if got := Parse(tc.in, a).String(); got != tc.want {
			t.Errorf("Parse(%q) = %s, want %s", tc.in, got, tc.want)
		}
	}
}

func atomTerms(ns []*Node) [][]string {
	var out [][]string
	for _, n := range ns {
		out = append(out, n.Terms)
	}
	return out
}

func TestPositiveAtoms(t *testing.T) {
	a := analysis.NewAnalyzer()
	tests := []struct {
		in   string
		want [][]string
	}{
		{"NOT cat", nil},
		{"cat NOT dog", [][]string{{"cat"}}},
		{"cat cat dog", [][]string{{"cat"}, {"dog"}}},
		{"NOT (cat NOT dog)", [][]string{{"dog"}}},
		{"NOT NOT cat", [][]string{{"cat"}}},
		{`"big cat" big`, [][]string{{"big", "cat"}, {"big"}}},
		{"", nil},
	}
	for _, tc := range tests {
		got := atomTerms(Parse(tc.in, a).PositiveAtoms())
		if !reflect.DeepEqual(got, tc.want) {
			t.Errorf("PositiveAtoms(%q) = %v, want %v", tc.in, got, tc.want)
		}
	}
	if n := len(Parse("cat NOT cat dog", a).Atoms()); n != 2 {
		t.Errorf("Atoms count = %d, want 2", n)
	}
}
