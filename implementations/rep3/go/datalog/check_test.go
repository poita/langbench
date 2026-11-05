package datalog

import (
	"errors"
	"testing"
)

func TestCheck(t *testing.T) {
	tests := []struct {
		name string
		src  string
		want error
	}{
		{"fine", "e(1,2). p(X,Y) :- e(X,Y). q(X) :- e(X,_), not p(X,X).", nil},
		{"fact with variable", "p(X).", ErrUnsafe},
		{"fact with anon", "p(_).", ErrUnsafe},
		{"head var unbound", "q(1). p(X) :- q(Y).", ErrUnsafe},
		{"head anon", "q(1). p(_) :- q(1).", ErrUnsafe},
		{"negated var unbound", "q(1). p(1) :- q(X), not r(Y).", ErrUnsafe},
		{"negated anon", "q(1). p(1) :- q(X), not r(_).", ErrUnsafe},
		{"comparison binds nothing", "q(1). p(Y) :- q(X), X = Y.", ErrUnsafe},
		{"comparison unbound", "q(1). p(X) :- q(X), Y = 5.", ErrUnsafe},
		{"comparison with anon", "q(1). p(X) :- q(X), _ < 3.", ErrUnsafe},
		{"var bound only by negation", "q(1). p(X) :- not q(X).", ErrUnsafe},
		{"ground rule without positives", "p(a) :- not q(b), 1 < 2.", nil},
		{"anon in positive ok", "q(1,2). p(X) :- q(X, _).", nil},
		{"self negation", "e(1). w(X) :- e(X), not w(X).", ErrNotStratifiable},
		{"negative cycle of two", "a(X) :- e(X), not b(X). b(X) :- e(X), a(X).", ErrNotStratifiable},
		{"long negative cycle", "a(X) :- b(X). b(X) :- c(X). c(X) :- e(X), not a(X).", ErrNotStratifiable},
		{"negation across components", "e(1). a(X) :- e(X). b(X) :- e(X), not a(X). a(X) :- b(X), e(X), X > 1, e(X).", ErrNotStratifiable},
		{"positive cycle with outside negation", "e(1). a(X) :- b(X). b(X) :- a(X). c(X) :- e(X), not a(X).", nil},
		{"same name other arity", "p(1). p(X, Y) :- p(X), p(Y), not p(X, Y).", ErrNotStratifiable},
		{"different arity negation ok", "p(1). q(X) :- p(X), not p(X, X).", nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := mustParse(t, tc.src).Check()
			if !errors.Is(err, tc.want) {
				t.Fatalf("Check = %v, want %v", err, tc.want)
			}
			if tc.want != nil {
				if _, serr := mustParse(t, tc.src).Solve(); !errors.Is(serr, tc.want) {
					t.Fatalf("Solve = %v, want %v", serr, tc.want)
				}
			}
		})
	}
}

func TestUnsafeReportedBeforeUnstratifiable(t *testing.T) {
	err := mustParse(t, "e(1). w(X) :- e(X), not w(X). p(X).").Check()
	if !errors.Is(err, ErrUnsafe) {
		t.Fatalf("Check = %v, want ErrUnsafe", err)
	}
}

func TestStratifyOrder(t *testing.T) {
	p := mustParse(t, "c(X) :- b(X). b(X) :- a(X). a(1).")
	st, err := p.stratify()
	if err != nil {
		t.Fatal(err)
	}
	id := func(name string) int32 {
		for i, pi := range p.preds {
			if pi.name == name {
				return int32(i)
			}
		}
		t.Fatalf("no predicate %s", name)
		return -1
	}
	if !(st.compOf[id("a")] < st.compOf[id("b")] && st.compOf[id("b")] < st.compOf[id("c")]) {
		t.Fatalf("components not in dependency order: %v", st.compOf)
	}
}
