package engine

import (
	"fmt"
	"testing"

	"datalog/analysis"
	"datalog/ast"
	"datalog/parser"
)

func eval(t *testing.T, src string) (*ast.Program, *Database) {
	t.Helper()
	p, err := parser.Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if err := analysis.CheckSafety(p); err != nil {
		t.Fatal(err)
	}
	s, err := analysis.Stratify(p)
	if err != nil {
		t.Fatal(err)
	}
	return p, Evaluate(p, s)
}

func TestRelationSet(t *testing.T) {
	r := newRelation(2)
	for i := 0; i < 1000; i++ {
		if !r.Add([]int32{int32(i), int32(i % 7)}) {
			t.Fatalf("tuple %d reported duplicate", i)
		}
	}
	if r.Add([]int32{5, 5}) {
		t.Error("duplicate accepted")
	}
	if r.Len() != 1000 || !r.Contains([]int32{999, 999 % 7}) || r.Contains([]int32{1, 2}) {
		t.Error("membership wrong")
	}
	if got := r.Tuple(3); got[0] != 3 || got[1] != 3 {
		t.Errorf("Tuple(3) = %v", got)
	}
}

func TestIndexIncremental(t *testing.T) {
	r := newRelation(2)
	ix := r.index([]int{0})
	for i := 0; i < 30; i++ {
		r.Add([]int32{int32(i % 3), int32(i)})
	}
	ix.Update()
	for i := 30; i < 60; i++ {
		r.Add([]int32{int32(i % 3), int32(i)})
	}
	ix.Update()
	var got []int32
	for p := ix.first([]int32{1}); p >= 0; p = ix.next[p] {
		got = append(got, r.Tuple(int(p))[1])
	}
	if len(got) != 20 {
		t.Fatalf("got %d entries: %v", len(got), got)
	}
	for i, v := range got {
		if v != int32(1+3*i) {
			t.Fatalf("bucket not ascending/complete: %v", got)
		}
	}
	if ix.first([]int32{9}) != -1 {
		t.Error("absent key found")
	}
	if r.index([]int{0}) != ix {
		t.Error("index not reused")
	}
}

func rows(p *ast.Program, db *Database, q string) []string {
	var out []string
	for _, row := range db.Match(findQuery(p, q)) {
		s := ""
		for _, id := range row {
			s += p.Consts[id].String() + " "
		}
		out = append(out, s)
	}
	return out
}

func findQuery(p *ast.Program, name string) ast.Atom {
	for _, q := range p.Queries {
		if p.Preds[q.Pred].Name == name {
			return q
		}
	}
	panic("no query " + name)
}

func TestTransitiveClosureNonLinear(t *testing.T) {
	src := "e(1,2). e(2,3). e(3,4). e(4,5). e(5,6)."
	src += "link(X,Y) :- e(X,Y). link(X,Z) :- link(X,Y), link(Y,Z). ?- link(X,Y)."
	p, db := eval(t, src)
	if got := len(rows(p, db, "link")); got != 15 {
		t.Errorf("got %d tuples, want 15", got)
	}
}

func TestMutualRecursion(t *testing.T) {
	src := `n(0). n(1). n(2). n(3). n(4). s(0,1). s(1,2). s(2,3). s(3,4).
		even(0).
		odd(Y) :- even(X), s(X, Y).
		even(Y) :- odd(X), s(X, Y).
		?- even(X). ?- odd(X).`
	p, db := eval(t, src)
	if got := fmt.Sprint(rows(p, db, "even")); got != "[0  2  4 ]" {
		t.Errorf("even: %s", got)
	}
	if got := fmt.Sprint(rows(p, db, "odd")); got != "[1  3 ]" {
		t.Errorf("odd: %s", got)
	}
}

func TestNegationAndComparison(t *testing.T) {
	src := `node(a). node(b). node(c). node(5). node(-2).
		link(a,b). link(b,5). link(5,5).
		hasout(X) :- link(X, _).
		sink(X) :- node(X), not hasout(X).
		small(X) :- node(X), X < a.
		?- sink(X). ?- small(X).`
	p, db := eval(t, src)
	if got := fmt.Sprint(rows(p, db, "sink")); got != "[-2  c ]" {
		t.Errorf("sink: %s", got)
	}
	if got := fmt.Sprint(rows(p, db, "small")); got != "[-2  5 ]" {
		t.Errorf("small: %s", got)
	}
}

func TestRepeatedVariables(t *testing.T) {
	src := `edge(1,1). edge(1,2). edge(2,2). edge(2,3).
		loop(X) :- edge(X, X).
		tri(X) :- edge(X, Y), edge(Y, Y).
		?- loop(X). ?- tri(X). ?- edge(X, X).`
	p, db := eval(t, src)
	if got := fmt.Sprint(rows(p, db, "loop")); got != "[1  2 ]" {
		t.Errorf("loop: %s", got)
	}
	if got := fmt.Sprint(rows(p, db, "tri")); got != "[1  2 ]" {
		t.Errorf("tri: %s", got)
	}
	if got := len(rows(p, db, "edge")); got != 2 {
		t.Errorf("edge(X,X) matched %d tuples", got)
	}
}

func TestBodylessConstantRule(t *testing.T) {
	p, db := eval(t, "p(a) :- 1 < 2. q(a) :- 2 < 1. ?- p(X). ?- q(X).")
	if len(rows(p, db, "p")) != 1 || len(rows(p, db, "q")) != 0 {
		t.Error("constant comparison rules wrong")
	}
}

func TestMatchPatterns(t *testing.T) {
	p, db := eval(t, "r(1,a). r(1,b). r(2,a). ?- r(1, X). ?- r(X, a). ?- r(2, a). ?- r(3, a).")
	for i, want := range []int{2, 2, 1, 0} {
		if got := len(db.Match(p.Queries[i])); got != want {
			t.Errorf("query %d: %d matches, want %d", i, got, want)
		}
	}
}

func TestChainClosureLarge(t *testing.T) {
	const n = 300
	src := ""
	for i := 1; i < n; i++ {
		src += fmt.Sprintf("e(%d,%d). ", i, i+1)
	}
	src += "p(X,Y) :- e(X,Y). p(X,Z) :- e(X,Y), p(Y,Z). ?- p(X,Y)."
	p, db := eval(t, src)
	if got, want := db.Relation(findQuery(p, "p").Pred).Len(), n*(n-1)/2; got != want {
		t.Errorf("closure has %d tuples, want %d", got, want)
	}
}
