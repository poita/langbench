package types

import (
	"errors"
	"testing"
)

func TestString(t *testing.T) {
	c := NewContext()
	a, b := c.NewVar(), c.NewVar()
	pair := func(x, y *Type) *Type { return Tuple([]*Type{x, y}) }
	tests := []struct {
		name string
		typ  *Type
		want string
	}{
		{"int", Int, "int"},
		{"var", a, "'a"},
		{"arrow chain", Arrow(a, Arrow(b, a)), "'a -> 'b -> 'a"},
		{"arrow on left", Arrow(Arrow(a, b), List(a)), "('a -> 'b) -> 'a list"},
		{"tuple in arrow", Arrow(pair(a, b), pair(b, a)), "'a * 'b -> 'b * 'a"},
		{"tuple components", Tuple([]*Type{Arrow(Int, Int), pair(Int, Int), Int}), "(int -> int) * (int * int) * int"},
		{"list of function", List(Arrow(a, a)), "('a -> 'a) list"},
		{"list of tuple", List(pair(Int, Bool)), "(int * bool) list"},
		{"list of list", List(List(Unit)), "unit list list"},
		{"list of list of arrow", List(List(Arrow(Int, Int))), "(int -> int) list list"},
	}
	for _, tc := range tests {
		if got := tc.typ.String(); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestVarName(t *testing.T) {
	for i, want := range map[int]string{0: "'a", 1: "'b", 25: "'z", 26: "'a1", 27: "'b1", 52: "'a2", 8000: "'s307"} {
		if got := VarName(i); got != want {
			t.Errorf("VarName(%d) = %q, want %q", i, got, want)
		}
	}
}

func TestPrintNamesByFirstAppearance(t *testing.T) {
	c := NewContext()
	a, b, d := c.NewVar(), c.NewVar(), c.NewVar()
	ty := Arrow(d, Arrow(a, Arrow(b, d)))
	if got, want := ty.String(), "'a -> 'b -> 'c -> 'a"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestUnify(t *testing.T) {
	c := NewContext()
	a, b := c.NewVar(), c.NewVar()
	if err := c.Unify(Arrow(a, Int), Arrow(Bool, b)); err != nil {
		t.Fatal(err)
	}
	if a.Resolve() != Bool || b.Resolve() != Int {
		t.Errorf("got a=%v b=%v", a, b)
	}
	if err := c.Unify(Int, Bool); !errors.Is(err, ErrUnify) {
		t.Errorf("int/bool: got %v", err)
	}
	if err := c.Unify(Tuple([]*Type{Int, Int}), Tuple([]*Type{Int, Int, Int})); !errors.Is(err, ErrUnify) {
		t.Errorf("tuple arity: got %v", err)
	}
	if err := c.Unify(Int, List(Int)); !errors.Is(err, ErrUnify) {
		t.Errorf("int/list: got %v", err)
	}
}

func TestOccursCheck(t *testing.T) {
	c := NewContext()
	a := c.NewVar()
	if err := c.Unify(a, List(a)); !errors.Is(err, ErrOccurs) {
		t.Errorf("got %v, want occurs", err)
	}
	b := c.NewVar()
	if err := c.Unify(Arrow(b, Int), Arrow(Arrow(b, Int), Int)); !errors.Is(err, ErrOccurs) {
		t.Errorf("got %v, want occurs", err)
	}
}

func TestUnifyLowersLevels(t *testing.T) {
	c := NewContext()
	outer := c.NewVar() // level 0
	c.EnterLevel()
	inner := c.NewVar() // level 1
	if err := c.Unify(outer, List(inner)); err != nil {
		t.Fatal(err)
	}
	c.LeaveLevel()
	s := c.Generalize(outer)
	if s.Poly {
		t.Error("a variable reachable from a level-0 variable must not be generalised")
	}
}

func TestGeneralizeInstantiate(t *testing.T) {
	c := NewContext()
	c.EnterLevel()
	a, b := c.NewVar(), c.NewVar()
	ty := Arrow(a, Arrow(b, a))
	c.LeaveLevel()
	s := c.Generalize(ty)
	if !s.Poly {
		t.Fatal("expected a polymorphic scheme")
	}
	i1, i2 := c.Instantiate(s), c.Instantiate(s)
	if i1.String() != "'a -> 'b -> 'a" {
		t.Errorf("got %v", i1)
	}
	// The instances are independent of each other and of the scheme.
	if err := c.Unify(i1, Arrow(Int, Arrow(Bool, Int))); err != nil {
		t.Fatal(err)
	}
	if err := c.Unify(i2, Arrow(Bool, Arrow(Int, Bool))); err != nil {
		t.Fatal(err)
	}
	if got := c.Instantiate(s).String(); got != "'a -> 'b -> 'a" {
		t.Errorf("scheme was modified: %v", got)
	}
}

func TestInstantiateShares(t *testing.T) {
	c := NewContext()
	c.EnterLevel()
	a := c.NewVar()
	ground := List(Int)
	ty := Tuple([]*Type{ground, Arrow(a, a)})
	c.LeaveLevel()
	s := c.Generalize(ty)
	inst := c.Instantiate(s)
	if inst.Args()[0] != ground {
		t.Error("a sub-term without quantified variables should be shared")
	}
	mono := Mono(Int)
	if c.Instantiate(mono) != Int {
		t.Error("monomorphic scheme should instantiate to itself")
	}
}

// Types are DAGs; walks must not expand them into trees.
func TestSharedDAGIsLinear(t *testing.T) {
	c := NewContext()
	build := func(leaf *Type) *Type {
		ty := leaf
		for i := 0; i < 200; i++ {
			ty = Tuple([]*Type{ty, ty}) // 2^200 leaves when expanded
		}
		return ty
	}
	c.EnterLevel()
	v := c.NewVar()
	x, y := build(v), build(c.NewVar())
	c.LeaveLevel()
	if err := c.Unify(x, y); err != nil {
		t.Fatal(err)
	}
	s := c.Generalize(x)
	if !s.Poly {
		t.Error("expected quantified variable")
	}
	_ = c.Instantiate(s)
	z := build(Int)
	if err := c.Unify(z, build(Int)); err != nil {
		t.Fatal(err)
	}
	// Occurs check through the DAG.
	w := c.NewVar()
	if err := c.Unify(w, build(w)); !errors.Is(err, ErrOccurs) {
		t.Errorf("got %v, want occurs", err)
	}
}

func TestFailedUnifyDoesNotMergeConstructors(t *testing.T) {
	c := NewContext()
	l1 := List(Int)
	l2 := List(Bool)
	_ = c.Unify(Tuple([]*Type{l1, Int}), Tuple([]*Type{l2, Bool}))
	if l1.Resolve() == l2.Resolve() {
		t.Error("unequal constructors were merged")
	}
}

func TestTuplePanicsOnFewComponents(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("expected panic")
		}
	}()
	Tuple([]*Type{Int})
}
