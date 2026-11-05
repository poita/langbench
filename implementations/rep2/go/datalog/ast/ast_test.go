package ast

import "testing"

func TestCompare(t *testing.T) {
	i := func(v int64) Constant { return Constant{IsInt: true, Int: v} }
	s := func(n string) Constant { return Constant{Name: n} }
	ordered := []Constant{i(-5), i(0), i(7), i(1000000000), s("a"), s("a0"), s("a_"), s("a_b"), s("aa"), s("ab"), s("b")}
	for x := range ordered {
		for y := range ordered {
			want := 0
			if x < y {
				want = -1
			} else if x > y {
				want = 1
			}
			if got := Compare(ordered[x], ordered[y]); got != want {
				t.Errorf("Compare(%v, %v) = %d, want %d", ordered[x], ordered[y], got, want)
			}
		}
	}
}

func TestCmpOpHolds(t *testing.T) {
	cases := []struct {
		op   CmpOp
		a, b int32
		want bool
	}{
		{Eq, 1, 1, true}, {Eq, 1, 2, false}, {Ne, 1, 2, true}, {Ne, 2, 2, false},
		{Lt, 1, 2, true}, {Lt, 2, 2, false}, {Le, 2, 2, true}, {Le, 3, 2, false},
		{Gt, 3, 2, true}, {Gt, 2, 2, false}, {Ge, 2, 2, true}, {Ge, 1, 2, false},
	}
	for _, c := range cases {
		if got := c.op.Holds(c.a, c.b); got != c.want {
			t.Errorf("%d %v %d = %v", c.a, c.op, c.b, got)
		}
	}
}

func TestStrings(t *testing.T) {
	if (Constant{IsInt: true, Int: -12}).String() != "-12" || (Constant{Name: "foo"}).String() != "foo" {
		t.Error("Constant.String")
	}
	if (Pred{"r", 2}).String() != "r/2" || Le.String() != "<=" {
		t.Error("Pred/CmpOp String")
	}
}
