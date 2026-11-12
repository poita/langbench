package datalog_test

import (
	"bytes"
	"errors"
	"strings"
	"testing"

	"example.com/datalog"
	"example.com/datalog/parser"
)

func run(t *testing.T, src string) string {
	t.Helper()
	var out bytes.Buffer
	if err := datalog.Run(strings.NewReader(src), &out); err != nil {
		t.Fatal(err)
	}
	return out.String()
}

func TestRunExamples(t *testing.T) {
	cases := []struct{ name, in, out string }{
		{"closure", `edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
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
		{"mixed", `% nodes and links
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
		{"no queries", "p(1).", ""},
		{"empty", "", ""},
		{"undefined predicate", "?- nothing(X).", "-- 0\n"},
	}
	for _, c := range cases {
		if got := run(t, c.in); got != c.out {
			t.Errorf("%s:\ngot:\n%s\nwant:\n%s", c.name, got, c.out)
		}
	}
}

func TestErrors(t *testing.T) {
	cases := []struct {
		name, src string
		target    error
	}{
		{"unstratifiable", "edge(1, 2).\nwin(X) :- edge(X, Y), not win(Y).\n?- win(X).", datalog.ErrNotStratifiable},
		{"unsafe after query", "q(1).\n?- q(X).\np(X) :- q(Y).\n?- p(X).", datalog.ErrUnsafe},
		{"unsafe fact", "p(X).", datalog.ErrUnsafe},
	}
	for _, c := range cases {
		var out bytes.Buffer
		err := datalog.Run(strings.NewReader(c.src), &out)
		if !errors.Is(err, c.target) {
			t.Errorf("%s: err = %v", c.name, err)
		}
		if out.Len() != 0 {
			t.Errorf("%s: wrote output %q", c.name, out.String())
		}
	}
	var se *parser.SyntaxError
	if _, err := datalog.Load("p("); !errors.As(err, &se) {
		t.Errorf("syntax error: got %v", err)
	}
}

func TestAdHocQuery(t *testing.T) {
	db, err := datalog.Load("p(2, b). p(1, a). p(1, 5).")
	if err != nil {
		t.Fatal(err)
	}
	rows, err := db.Query("?- p(1, X).")
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, r := range rows {
		got = append(got, datalog.Format("p", r))
	}
	if strings.Join(got, ";") != "p(1, 5);p(1, a)" {
		t.Errorf("got %v", got)
	}
}
