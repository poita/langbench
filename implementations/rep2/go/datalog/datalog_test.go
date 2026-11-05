package datalog

import (
	"errors"
	"strings"
	"testing"
)

func TestRunExamples(t *testing.T) {
	cases := []struct{ name, in, out string }{
		{"closure", `
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(1, X).
?- path(4, X).
?- path(X, X).`, `path(1, 1)
path(1, 2)
path(1, 3)
path(1, 4)
-- 4
-- 0
path(1, 1)
path(2, 2)
path(3, 3)
-- 3
`},
		{"negation", `
% nodes and links
node(a). node(b). node(c). node(5). node(-2).
link(a, b). link(b, 5). link(5, 5).
reach(X, Y) :- link(X, Y).
reach(X, Z) :- reach(X, Y), link(Y, Z).
sink(X) :- node(X), not hasout(X).
hasout(X) :- link(X, _).
small(X) :- node(X), X < a.
?- sink(X).
?- small(X).
?- reach(a, X).
?- reach(X, X).`, `sink(-2)
sink(c)
-- 2
small(-2)
small(5)
-- 2
reach(a, 5)
reach(a, b)
-- 2
reach(5, 5)
-- 1
`},
		{"no queries", "p(a).", ""},
		{"undefined predicate", "?- nothing(X).", "-- 0\n"},
		{"arity namespaces", "r(a). r(b, c). ?- r(X). ?- r(X, Y). ?- r(X, Y, Z).",
			"r(a)\n-- 1\nr(b, c)\n-- 1\n-- 0\n"},
	}
	for _, c := range cases {
		out, err := Run([]byte(c.in))
		if err != nil {
			t.Errorf("%s: %v", c.name, err)
		} else if string(out) != c.out {
			t.Errorf("%s:\ngot:\n%s\nwant:\n%s", c.name, out, c.out)
		}
	}
}

func TestRunErrors(t *testing.T) {
	cases := []struct {
		name, in string
		want     error
	}{
		{"unstratifiable", "edge(1, 2).\nwin(X) :- edge(X, Y), not win(Y).\n?- win(X).", ErrNotStratifiable},
		{"unsafe head", "q(1).\n?- q(X).\np(X) :- q(Y).\n?- p(X).", ErrUnsafe},
		{"unsafe fact", "p(X).", ErrUnsafe},
		{"unsafe comparison", "q(1). p(Y) :- q(X), X = Y.", ErrUnsafe},
	}
	for _, c := range cases {
		out, err := Run([]byte(c.in))
		if !errors.Is(err, c.want) || len(out) != 0 || !IsRejected(err) {
			t.Errorf("%s: out=%q err=%v", c.name, out, err)
		}
	}
	_, err := Run([]byte("p("))
	var se *SyntaxError
	if !errors.As(err, &se) || IsRejected(err) {
		t.Errorf("syntax error: %v", err)
	}
}

func TestModelAPI(t *testing.T) {
	p, err := Parse([]byte("n(b). n(3). n(a). n(-1). m(X) :- n(X), X > 0. ?- m(X)."))
	if err != nil {
		t.Fatal(err)
	}
	m, err := p.Eval()
	if err != nil {
		t.Fatal(err)
	}
	if m.Queries() != 1 {
		t.Fatalf("queries = %d", m.Queries())
	}
	if got := m.Query(0).Format(); got != "m(3)\nm(a)\nm(b)\n-- 3\n" {
		t.Errorf("Query(0) = %q", got)
	}
	var names []string
	for _, tup := range m.Facts("n", 1) {
		names = append(names, tup[0].String())
	}
	if strings.Join(names, ",") != "-1,3,a,b" {
		t.Errorf("Facts = %v", names)
	}
	if m.Facts("zzz", 1) != nil || m.Facts("n", 2) != nil {
		t.Error("unknown predicate should have no facts")
	}
}
