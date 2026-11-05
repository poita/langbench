package datalog

import (
	"errors"
	"testing"
)

func checkSrc(t *testing.T, src string) error {
	t.Helper()
	prog, err := Parse([]byte(src))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	return prog.Check()
}

func TestSafety(t *testing.T) {
	unsafe := []string{
		"p(X).",
		"p(_).",
		"p(X) :- q(Y).",
		"p(X) :- q(X), not r(Y).",
		"p(X) :- q(X), not r(_).",
		"p(Y) :- q(X), X = Y.",
		"p(X) :- q(X), Y = 5.",
		"p(X) :- q(X), X < _.",
		"p(X) :- not q(X).",
	}
	for _, src := range unsafe {
		if err := checkSrc(t, src); !errors.Is(err, ErrUnsafe) {
			t.Errorf("%q: got %v, want ErrUnsafe", src, err)
		}
	}
	safe := []string{
		"p(1).",
		"p(X) :- q(X, _).",
		"p(X) :- q(X), not r(X), X < 3.",
		"p(1) :- 1 < 2.",
		"p(1) :- not q(2).",
	}
	for _, src := range safe {
		if err := checkSrc(t, src); err != nil {
			t.Errorf("%q: unexpected %v", src, err)
		}
	}
}

func TestStratification(t *testing.T) {
	bad := []string{
		"win(X) :- edge(X, Y), not win(Y).",
		"p(X) :- q(X), not r(X). r(X) :- s(X), p(X).",
		"p(X) :- q(X), not p(X).",
	}
	for _, src := range bad {
		if err := checkSrc(t, src); !errors.Is(err, ErrNotStratifiable) {
			t.Errorf("%q: got %v, want ErrNotStratifiable", src, err)
		}
	}
	good := []string{
		"p(X) :- q(X), not r(X). r(X) :- s(X).",
		"p(X) :- q(X). q(X) :- p(X). s(X) :- t(X), not p(X).",
	}
	for _, src := range good {
		if err := checkSrc(t, src); err != nil {
			t.Errorf("%q: unexpected %v", src, err)
		}
	}
}

func TestSafetyCheckedBeforeStratification(t *testing.T) {
	err := checkSrc(t, "win(X) :- e(X, Y), not win(Y). p(X) :- q(Y).")
	if !errors.Is(err, ErrUnsafe) {
		t.Errorf("got %v", err)
	}
}

func TestComponentOrder(t *testing.T) {
	prog, _ := Parse([]byte("c(X) :- b(X). b(X) :- a(X), not z(X). a(X) :- a(X), s(X)."))
	comps, err := prog.analyze()
	if err != nil {
		t.Fatal(err)
	}
	pos := map[string]int{}
	rec := map[string]bool{}
	for i, c := range comps {
		for _, p := range c.preds {
			pos[prog.Preds[p].Name] = i
			rec[prog.Preds[p].Name] = c.recursive
		}
	}
	if !(pos["a"] < pos["b"] && pos["b"] < pos["c"] && pos["z"] < pos["b"]) {
		t.Errorf("bad order %v", pos)
	}
	if !rec["a"] || rec["b"] || rec["c"] {
		t.Errorf("bad recursive flags %v", rec)
	}
}
