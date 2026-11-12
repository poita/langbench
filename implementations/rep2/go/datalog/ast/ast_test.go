package ast

import (
	"slices"
	"testing"
)

func TestCompareOrder(t *testing.T) {
	// Ascending order as given in the specification.
	ordered := []Constant{
		Int(-5), Int(0), Int(7), Int(1000000000),
		Sym("a"), Sym("a0"), Sym("a_"), Sym("a_b"), Sym("aa"), Sym("ab"), Sym("b"),
	}
	for i, x := range ordered {
		for j, y := range ordered {
			want := 0
			if i < j {
				want = -1
			} else if i > j {
				want = 1
			}
			if got := Compare(x, y); got != want {
				t.Errorf("Compare(%v, %v) = %d, want %d", x, y, got, want)
			}
		}
	}
	shuffled := slices.Clone(ordered)
	slices.Reverse(shuffled)
	slices.SortFunc(shuffled, Compare)
	if !slices.Equal(shuffled, ordered) {
		t.Errorf("sorted = %v", shuffled)
	}
}

func TestStrings(t *testing.T) {
	r := Rule{
		Head: Atom{"p", []Term{V("X"), C(Int(-3))}},
		Body: []Literal{
			{Kind: Positive, Atom: Atom{"q", []Term{V("X"), V("_0")}}},
			{Kind: Negative, Atom: Atom{"r", []Term{V("X")}}},
			{Kind: Comparison, Op: LE, Left: V("X"), Right: C(Sym("a"))},
		},
	}
	want := "p(X, -3) :- q(X, _), not r(X), X <= a."
	if got := r.String(); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestCmpOpHolds(t *testing.T) {
	cases := []struct {
		op   CmpOp
		c    int
		want bool
	}{
		{EQ, 0, true}, {EQ, 1, false}, {NE, 0, false}, {NE, -1, true},
		{LT, -1, true}, {LT, 0, false}, {LE, 0, true}, {LE, 1, false},
		{GT, 1, true}, {GT, 0, false}, {GE, 0, true}, {GE, -1, false},
	}
	for _, c := range cases {
		if got := c.op.Holds(c.c); got != c.want {
			t.Errorf("%v.Holds(%d) = %v", c.op, c.c, got)
		}
	}
}
