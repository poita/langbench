package parser

import (
	"errors"
	"testing"

	"example.com/datalog/ast"
)

func TestParseProgram(t *testing.T) {
	src := `% comment
edge(1, -2). edge(a,b).
path(X, Z) :- edge(X, Y), path(Y, Z), not bad(_), X<=-1, a != Z.
?- path(_, _). ?-edge(X,X).`
	prog, err := Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	if len(prog.Rules) != 3 || len(prog.Queries) != 2 {
		t.Fatalf("got %d rules, %d queries", len(prog.Rules), len(prog.Queries))
	}
	if got, want := prog.Rules[0].String(), "edge(1, -2)."; got != want {
		t.Errorf("rule 0 = %q, want %q", got, want)
	}
	want := "path(X, Z) :- edge(X, Y), path(Y, Z), not bad(_), X <= -1, a != Z."
	if got := prog.Rules[2].String(); got != want {
		t.Errorf("rule 2 = %q, want %q", got, want)
	}
	// Anonymous variables are distinct.
	q := prog.Queries[0]
	if q.Args[0].Var == q.Args[1].Var {
		t.Error("the two _ in the query share a name")
	}
}

func TestLexingEdgeCases(t *testing.T) {
	prog, err := Parse("p(X) :- q(X), X<-1, not_x(X), nothing(X).")
	if err != nil {
		t.Fatal(err)
	}
	body := prog.Rules[0].Body
	if body[1].Kind != ast.Comparison || body[1].Op != ast.LT || body[1].Right.Const != ast.Int(-1) {
		t.Errorf("X<-1 parsed as %v", body[1])
	}
	if body[2].Atom.Pred != "not_x" || body[3].Atom.Pred != "nothing" {
		t.Errorf("identifiers starting with not: %v %v", body[2], body[3])
	}
}

func TestEmptyAndComments(t *testing.T) {
	for _, src := range []string{"", "  \n\t", "% only a comment", "% a\n% b\n"} {
		prog, err := Parse(src)
		if err != nil || len(prog.Rules)+len(prog.Queries) != 0 {
			t.Errorf("Parse(%q) = %v, %v", src, prog, err)
		}
	}
}

func TestSyntaxErrors(t *testing.T) {
	for _, src := range []string{"p(", "p(X) :- .", "p(X) q(X).", "p(1) :- q(1) r(1).", "?- p(1)", "p(#).", "p() ."} {
		_, err := Parse(src)
		var se *SyntaxError
		if !errors.As(err, &se) {
			t.Errorf("Parse(%q): want SyntaxError, got %v", src, err)
		}
	}
}

func TestParseAtom(t *testing.T) {
	for _, src := range []string{"p(1, X)", "p(1, X).", "?- p(1, X)."} {
		a, err := ParseAtom(src)
		if err != nil || a.String() != "p(1, X)" {
			t.Errorf("ParseAtom(%q) = %v, %v", src, a, err)
		}
	}
	if _, err := ParseAtom("p(1) q(2)"); err == nil {
		t.Error("trailing input accepted")
	}
}
