package analysis

import (
	"errors"
	"testing"

	"datalog/ast"
	"datalog/parser"
)

func mustParse(t *testing.T, src string) *ast.Program {
	t.Helper()
	p, err := parser.Parse([]byte(src))
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
		{"p(X) :- q(X).", true},
		{"p(a).", true},
		{"p(X).", false},
		{"p(_).", false},
		{"p(X) :- q(Y).", false},
		{"p(X) :- q(X), not r(X).", true},
		{"p(X) :- q(X), not r(X, Y).", false},
		{"p(X) :- q(X), not r(_).", false},
		{"p(X) :- q(X, _).", true},
		{"p(Y) :- q(X), X = Y.", false},
		{"p(X) :- q(X), Y = 5.", false},
		{"p(X) :- q(X), X < 5, 1 != 2.", true},
		{"p(X) :- q(X), _ = 3.", false},
		{"p(a) :- 1 < 2.", true},
	}
	for _, c := range cases {
		err := CheckSafety(mustParse(t, c.src))
		if c.safe && err != nil {
			t.Errorf("%q: unexpected %v", c.src, err)
		}
		if !c.safe && !errors.Is(err, ErrUnsafe) {
			t.Errorf("%q: expected ErrUnsafe, got %v", c.src, err)
		}
	}
}

func TestStratify(t *testing.T) {
	cases := []struct {
		src string
		ok  bool
	}{
		{"win(X) :- e(X, Y), not win(Y).", false},
		{"a(X) :- d(X), not b(X). b(X) :- d(X), not a(X).", false},
		{"a(X) :- d(X), not b(X). b(X) :- d(X), c(X). c(X) :- a(X).", false},
		{"p(X) :- d(X), not q(X). q(X) :- r(X). r(X) :- q(X).", true},
		{"p(X) :- p(X), q(X). q(X) :- d(X), not p2(X).", true},
		{"p(X) :- q(X), not undefined(X).", true},
	}
	for _, c := range cases {
		_, err := Stratify(mustParse(t, c.src))
		if c.ok && err != nil {
			t.Errorf("%q: unexpected %v", c.src, err)
		}
		if !c.ok && !errors.Is(err, ErrNotStratifiable) {
			t.Errorf("%q: expected ErrNotStratifiable, got %v", c.src, err)
		}
	}
}

func TestComponentOrder(t *testing.T) {
	p := mustParse(t, `
		top(X) :- mid(X), not low(X).
		mid(X) :- base(X).
		mid(X) :- mid(X), base(X).
		low(X) :- base(X).`)
	s, err := Stratify(p)
	if err != nil {
		t.Fatal(err)
	}
	id := map[string]int{}
	for i, pr := range p.Preds {
		id[pr.Name] = i
	}
	if s.Comp[id["base"]] >= s.Comp[id["mid"]] || s.Comp[id["mid"]] >= s.Comp[id["top"]] ||
		s.Comp[id["low"]] >= s.Comp[id["top"]] {
		t.Errorf("components not in dependency order: %v", s.Comp)
	}
	if !s.Recursive[s.Comp[id["mid"]]] || s.Recursive[s.Comp[id["top"]]] {
		t.Errorf("recursive flags wrong: %v", s.Recursive)
	}
}
