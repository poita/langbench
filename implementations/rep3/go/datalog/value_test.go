package datalog

import "testing"

func TestValueCompare(t *testing.T) {
	// Strictly ascending in the language order.
	order := []Value{
		Int(-5), Int(0), Int(7), Int(100),
		Sym("a"), Sym("a0"), Sym("a_"), Sym("a_b"), Sym("aa"), Sym("ab"), Sym("b"),
	}
	for i, a := range order {
		for j, b := range order {
			want := 0
			if i < j {
				want = -1
			} else if i > j {
				want = 1
			}
			if got := a.Compare(b); got != want {
				t.Errorf("Compare(%v, %v) = %d, want %d", a, b, got, want)
			}
		}
	}
}

func TestValueString(t *testing.T) {
	if s := Int(-12).String(); s != "-12" {
		t.Errorf("got %q", s)
	}
	if s := Sym("abc").String(); s != "abc" {
		t.Errorf("got %q", s)
	}
	if !Int(1).IsInt() || Sym("a").IsInt() || Int(4).Int() != 4 || Sym("q").Name() != "q" {
		t.Error("accessors misbehave")
	}
}

func TestCompareTuples(t *testing.T) {
	if CompareTuples([]Value{Int(1), Sym("a")}, []Value{Int(1), Sym("b")}) >= 0 {
		t.Error("expected less")
	}
	if CompareTuples([]Value{Int(1)}, []Value{Int(1), Int(2)}) >= 0 {
		t.Error("prefix should sort first")
	}
	if CompareTuples([]Value{Sym("a")}, []Value{Sym("a")}) != 0 {
		t.Error("expected equal")
	}
}
