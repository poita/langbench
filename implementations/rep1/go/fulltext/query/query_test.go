package query

import (
	"reflect"
	"testing"
)

// show renders a tree as a compact s-expression for comparison.
func show(n *Node) string {
	if n == nil {
		return "()"
	}
	switch n.Op {
	case Atom:
		s := "["
		for i, t := range n.Terms {
			if i > 0 {
				s += " "
			}
			s += t
		}
		return s + "]"
	case Not:
		return "(NOT " + show(n.Children[0]) + ")"
	}
	name := "AND"
	if n.Op == Or {
		name = "OR"
	}
	s := "(" + name
	for _, c := range n.Children {
		s += " " + show(c)
	}
	return s + ")"
}

func TestParse(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", "()"},
		{"()", "()"},
		{"the", "()"},
		{"NOT", "()"},
		{"cat", "[cat]"},
		{"cat AND", "[cat]"},
		{"OR cat", "[cat]"},
		{"cat ()", "[cat]"},
		{"cat NOT ()", "[cat]"},
		{"cat NOT (", "[cat]"},
		{"(cat", "[cat]"},
		{`"cat`, "[cat]"},
		{"cat ) dog", "[cat]"},
		{"cat ) ) dog", "[cat]"},
		{"cat OR AND dog", "(OR [cat] [dog])"},
		{"cat AND OR dog", "(OR [cat] [dog])"},
		{"cat AND AND dog", "(AND [cat] [dog])"},
		{"dog NOT ( cat", "(AND [dog] (NOT [cat]))"},
		{"cat dog", "(AND [cat] [dog])"},
		{"x OR b c", "(OR [x] (AND [b] [c]))"},
		{"NOT NOT cat", "(NOT (NOT [cat]))"},
		{`"to be or not to be"`, "[to be or not to be]"},
		{"well-known", "[well known]"},
		{`"lazy dog" or`, "[lazi dog]"}, // lower-case "or" is an empty stop-word atom
		{"cats AND (dogs OR bird)", "(AND [cat] (OR [dog] [bird]))"},
		{`""`, "()"},
		{"cat dog", "(AND [cat] [dog])"},
		{"and", "()"},
		{"NOT OR cat", "[cat]"},
	}
	for _, c := range cases {
		got := show(Parse(c.in))
		want := c.want
		if got != want {
			t.Errorf("Parse(%q) = %s, want %s", c.in, got, want)
		}
	}
}

func TestPositiveAtoms(t *testing.T) {
	got := PositiveAtoms(Parse("cat NOT dog NOT NOT bird cat"))
	want := [][]string{{"cat"}, {"bird"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
	if got := PositiveAtoms(Parse("NOT cat")); len(got) != 0 {
		t.Fatalf("got %v", got)
	}
	if got := Atoms(Parse("NOT cat dog")); len(got) != 2 {
		t.Fatalf("got %v", got)
	}
}

func TestTrimSpace(t *testing.T) {
	if got := TrimSpace("  \tab c  \n"); got != "ab c" {
		t.Fatalf("got %q", got)
	}
}
