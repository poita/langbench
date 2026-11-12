package analysis

import (
	"errors"
	"testing"

	"example.com/datalog/ast"
	"example.com/datalog/parser"
)

func rules(t *testing.T, src string) []ast.Rule {
	t.Helper()
	p, err := parser.Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	return p.Rules
}

func TestSafety(t *testing.T) {
	unsafe := []string{
		"p(X).",
		"p(_).",
		"p(X) :- q(Y).",
		"p(X) :- q(X), not r(Y).",
		"p(X) :- q(X), X < Y.",
		"p(Y) :- q(X), X = Y.",
		"p(X) :- q(X), Y = 5.",
		"p(X) :- not q(X).",
		"p(X) :- q(X), not r(_).",
		"p(X) :- q(X), _ < 3.",
		"p(X) :- q(X), r(Y), not s(Z).",
	}
	for _, src := range unsafe {
		var ue *UnsafeError
		if err := CheckSafety(rules(t, src)); !errors.As(err, &ue) {
			t.Errorf("%q: err = %v, want UnsafeError", src, err)
		}
	}
	safe := []string{
		"p(1).",
		"p(X) :- q(X).",
		"p(X) :- q(X, _).",
		"p(X) :- q(X), not r(X), X < 3, 1 = 1.",
		"p(X) :- not r(3), q(X).",
		"p(X, Y) :- q(X), r(Y), X != Y.",
	}
	for _, src := range safe {
		if err := CheckSafety(rules(t, src)); err != nil {
			t.Errorf("%q: %v", src, err)
		}
	}
}

func names(c Component) []string {
	var s []string
	for _, p := range c.Preds {
		s = append(s, p.Name)
	}
	return s
}

func TestStratifyOrder(t *testing.T) {
	comps, err := Stratify(rules(t, `
		sink(X) :- node(X), not hasout(X).
		hasout(X) :- link(X, _).
		reach(X, Y) :- link(X, Y).
		reach(X, Z) :- reach(X, Y), link(Y, Z).
		small(X) :- reach(X, _), sink(X).
	`))
	if err != nil {
		t.Fatal(err)
	}
	pos := map[string]int{}
	rec := map[string]bool{}
	for i, c := range comps {
		for _, n := range names(c) {
			pos[n] = i
			rec[n] = c.Recursive
		}
	}
	before := [][2]string{{"link", "hasout"}, {"hasout", "sink"}, {"node", "sink"}, {"link", "reach"}, {"reach", "small"}, {"sink", "small"}}
	for _, b := range before {
		if pos[b[0]] >= pos[b[1]] {
			t.Errorf("%s must be evaluated before %s: %v", b[0], b[1], pos)
		}
	}
	if !rec["reach"] || rec["sink"] || rec["link"] {
		t.Errorf("recursive flags: %v", rec)
	}
}

func TestMutualRecursionIsOneComponent(t *testing.T) {
	comps, err := Stratify(rules(t, `
		even(X) :- zero(X).
		even(X) :- succ(Y, X), odd(Y).
		odd(X) :- succ(Y, X), even(Y).
	`))
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, c := range comps {
		if len(c.Preds) == 2 {
			found = c.Recursive
		}
	}
	if !found {
		t.Errorf("comps = %v", comps)
	}
}

func TestNotStratifiable(t *testing.T) {
	bad := []string{
		"win(X) :- edge(X, Y), not win(Y).",
		"a(X) :- n(X), not b(X). b(X) :- n(X), a(X).",
		"a(X) :- n(X), not b(X). b(X) :- c(X). c(X) :- a(X).",
	}
	for _, src := range bad {
		var ne *NotStratifiableError
		if _, err := Stratify(rules(t, src)); !errors.As(err, &ne) {
			t.Errorf("%q: err = %v", src, err)
		}
	}
	// Negation across arities of one name is fine: p/1 and p/2 differ.
	if _, err := Stratify(rules(t, "p(X) :- q(X), not p(X, X).")); err != nil {
		t.Errorf("distinct arities: %v", err)
	}
}
