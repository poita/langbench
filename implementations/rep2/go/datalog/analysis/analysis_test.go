package analysis

import (
	"errors"
	"testing"

	"example.com/datalog/ast"
	"example.com/datalog/parser"
)

func mustParse(t *testing.T, src string) *ast.Program {
	t.Helper()
	p, err := parser.Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestSafety(t *testing.T) {
	cases := []struct {
		src  string
		safe bool
	}{
		{"p(a). p(X) :- q(X).", true},
		{"p(X) :- q(X, _), not r(X), X < 3.", true},
		{"p(a) :- 1 < 2.", true},
		{"p(a) :- not q(b).", true},
		{"p(X).", false},
		{"p(_).", false},
		{"p(X) :- q(Y).", false},
		{"p(X) :- q(X), not r(Y).", false},
		{"p(X) :- q(X), not r(_).", false},
		{"p(X) :- q(X), X < Y.", false},
		{"p(Y) :- q(X), X = Y.", false},
		{"p(X) :- q(X), Y = 5.", false},
		{"p(X) :- not q(X), r(X).", true},
	}
	for _, c := range cases {
		err := CheckSafety(mustParse(t, c.src))
		if c.safe && err != nil {
			t.Errorf("%q: unexpected %v", c.src, err)
		}
		if !c.safe && !errors.Is(err, ErrUnsafe) {
			t.Errorf("%q: want ErrUnsafe, got %v", c.src, err)
		}
	}
}

func TestStratify(t *testing.T) {
	cases := []struct {
		src string
		ok  bool
	}{
		{"p(X) :- q(X).", true},
		{"p(X) :- q(X), not r(X). r(X) :- s(X).", true},
		{"win(X) :- e(X, Y), not win(Y).", false},
		{"p(X) :- q(X), not r(X). r(X) :- p(X).", false},
		{"p(X) :- q(X), not r(X). r(X) :- s(X), not t(X). t(X) :- u(X).", true},
		{"a(X) :- b(X). b(X) :- a(X). c(X) :- d(X), not a(X).", true},
		{"a(X) :- b(X). b(X) :- c(X). c(X) :- d(X), not a(X).", false},
	}
	for _, c := range cases {
		_, err := Stratify(mustParse(t, c.src))
		if c.ok && err != nil {
			t.Errorf("%q: unexpected %v", c.src, err)
		}
		if !c.ok && !errors.Is(err, ErrNotStratifiable) {
			t.Errorf("%q: want ErrNotStratifiable, got %v", c.src, err)
		}
	}
}

func TestStratifyOrder(t *testing.T) {
	prog := mustParse(t, "c(X) :- b(X), not a(X). b(X) :- a(X). a(1). ?- z(X).")
	comps, err := Stratify(prog)
	if err != nil {
		t.Fatal(err)
	}
	pos := map[string]int{}
	for i, c := range comps {
		for _, p := range c {
			pos[p.Name] = i
		}
	}
	if len(pos) != 4 {
		t.Errorf("predicates = %v, want a, b, c, z", pos)
	}
	if !(pos["a"] < pos["b"] && pos["b"] < pos["c"]) {
		t.Errorf("bad evaluation order %v", comps)
	}
}

func TestArityDistinguishesPredicates(t *testing.T) {
	// r/1 and r/2 are different predicates: no cycle here.
	if _, err := Stratify(mustParse(t, "r(X, Y) :- s(X, Y), not r(X).")); err != nil {
		t.Errorf("unexpected %v", err)
	}
}
