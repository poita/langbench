package ast

import (
	"slices"
	"testing"
)

func TestCompareOrder(t *testing.T) {
	// Ascending order as given in the specification.
	ordered := []Value{
		Int(-5), Int(-1), Int(0), Int(7), Int(1000000000),
		Sym("a"), Sym("a0"), Sym("a_"), Sym("a_b"), Sym("aa"), Sym("ab"), Sym("b"),
	}
	for i, a := range ordered {
		for j, b := range ordered {
			want := 0
			if i < j {
				want = -1
			} else if i > j {
				want = 1
			}
			if got := Compare(a, b); got != want {
				t.Errorf("Compare(%v, %v) = %d, want %d", a, b, got, want)
			}
		}
	}
	shuffled := slices.Clone(ordered)
	slices.Reverse(shuffled)
	slices.SortFunc(shuffled, Compare)
	if !slices.Equal(shuffled, ordered) {
		t.Errorf("sorted = %v, want %v", shuffled, ordered)
	}
}

func TestValueAccessors(t *testing.T) {
	if v := Int(-12); !v.IsInt() || v.Int64() != -12 || v.String() != "-12" {
		t.Errorf("Int(-12) = %#v", v)
	}
	if v := Sym("abc"); v.IsInt() || v.Symbol() != "abc" || v.String() != "abc" {
		t.Errorf("Sym(abc) = %#v", v)
	}
	if Int(5) == Sym("5") {
		t.Error("integer 5 must differ from symbol 5")
	}
}

func TestRuleString(t *testing.T) {
	r := Rule{
		Head: Atom{"p", []Term{Var("X"), Const(Int(3))}},
		Body: []Literal{
			{Kind: Positive, Atom: Atom{"q", []Term{Var("X"), Var("_1")}}},
			{Kind: Negative, Atom: Atom{"r", []Term{Var("X")}}},
			{Kind: Comparison, Op: Le, Left: Var("X"), Right: Const(Sym("z"))},
		},
	}
	want := "p(X, 3) :- q(X, _), not r(X), X <= z."
	if got := r.String(); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if got := (Rule{Head: Atom{"f", []Term{Const(Sym("a"))}}}).String(); got != "f(a)." {
		t.Errorf("fact = %q", got)
	}
	if got := (Pred{"edge", 2}).String(); got != "edge/2" {
		t.Errorf("pred = %q", got)
	}
}

func TestCmpOpHolds(t *testing.T) {
	cases := []struct {
		op   CmpOp
		c    int
		want bool
	}{
		{Eq, 0, true}, {Eq, 1, false}, {Ne, 0, false}, {Ne, -1, true},
		{Lt, -1, true}, {Lt, 0, false}, {Le, 0, true}, {Le, 1, false},
		{Gt, 1, true}, {Gt, 0, false}, {Ge, 0, true}, {Ge, -1, false},
	}
	for _, c := range cases {
		if got := c.op.Holds(c.c); got != c.want {
			t.Errorf("%v.Holds(%d) = %v", c.op, c.c, got)
		}
	}
}
