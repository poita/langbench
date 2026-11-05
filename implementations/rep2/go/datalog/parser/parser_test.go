package parser

import (
	"errors"
	"testing"

	"datalog/ast"
)

func constNames(p *ast.Program) []string {
	var s []string
	for _, c := range p.Consts {
		s = append(s, c.String())
	}
	return s
}

func TestConstantOrder(t *testing.T) {
	p, err := Parse([]byte("r(b, 10, a_, -3, a0, a, aa, 0, ab, a_b)."))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"-3", "0", "10", "a", "a0", "a_", "a_b", "aa", "ab", "b"}
	got := constNames(p)
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
	// The fact's arguments must have been renumbered to ranks.
	args := p.Rules[0].Head.Args
	if p.Consts[args[0].ID].Name != "b" || p.Consts[args[3].ID].Int != -3 {
		t.Errorf("arguments not renumbered: %+v", args)
	}
}

func TestClauseStructure(t *testing.T) {
	src := `% comment
	edge(1,2). path(X,Y):-edge(X,Y),not blocked(X),X<=Y, Y != 3.%tail
	?- path(_, Z). ?-path(1,_).`
	p, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Rules) != 2 || len(p.Queries) != 2 {
		t.Fatalf("rules=%d queries=%d", len(p.Rules), len(p.Queries))
	}
	r := p.Rules[1]
	if len(r.Body) != 4 || r.NumVars != 2 {
		t.Fatalf("body=%d vars=%d", len(r.Body), r.NumVars)
	}
	kinds := []ast.LitKind{ast.Positive, ast.Negative, ast.Comparison, ast.Comparison}
	for i, k := range kinds {
		if r.Body[i].Kind != k {
			t.Errorf("literal %d kind %v, want %v", i, r.Body[i].Kind, k)
		}
	}
	if r.Body[2].Op != ast.Le || r.Body[3].Op != ast.Ne {
		t.Errorf("ops: %v %v", r.Body[2].Op, r.Body[3].Op)
	}
	q := p.Queries[0]
	if q.Args[0].ID == q.Args[1].ID {
		t.Error("anonymous variable must get its own slot")
	}
}

func TestPredicatesByArity(t *testing.T) {
	p, err := Parse([]byte("r(a). r(a, b). s(X) :- r(X, _)."))
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Preds) != 3 || p.Preds[0].Arity != 1 || p.Preds[1].Arity != 2 {
		t.Errorf("preds: %v", p.Preds)
	}
}

func TestLexingEdgeCases(t *testing.T) {
	// "X<-1" lexes as X < -1; "nothing" and "not_x" are identifiers; the
	// constant "edge" may also be a predicate name.
	p, err := Parse([]byte("p(X) :- q(X), X<-1. q(nothing). q(not_x). e(edge, edge)."))
	if err != nil {
		t.Fatal(err)
	}
	cmp := p.Rules[0].Body[1]
	if cmp.Kind != ast.Comparison || cmp.Op != ast.Lt || p.Consts[cmp.Right.ID].Int != -1 {
		t.Errorf("bad comparison: %+v", cmp)
	}
}

func TestComparisonWithConstantOnLeft(t *testing.T) {
	p, err := Parse([]byte("p(X) :- q(X), a < X, 3 = X."))
	if err != nil {
		t.Fatal(err)
	}
	if got := len(p.Rules[0].Body); got != 3 {
		t.Fatalf("body has %d literals", got)
	}
}

func TestEmptyAndCommentOnly(t *testing.T) {
	for _, src := range []string{"", "  \n\t", "% just a comment\n%another"} {
		p, err := Parse([]byte(src))
		if err != nil || len(p.Rules)+len(p.Queries) != 0 {
			t.Errorf("%q: %v %v", src, p, err)
		}
	}
}

func TestSyntaxErrors(t *testing.T) {
	for _, src := range []string{"p(", "p(a)", "p(a) :- .", "p :- q(a).", "?- p(a)", "p(a) :- q(a) r(b).", "p(a) $"} {
		_, err := Parse([]byte(src))
		var se *SyntaxError
		if !errors.As(err, &se) {
			t.Errorf("%q: expected SyntaxError, got %v", src, err)
		}
	}
}
