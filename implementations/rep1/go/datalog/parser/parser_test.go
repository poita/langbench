package parser

import (
	"errors"
	"strings"
	"testing"

	"example.com/datalog/ast"
)

func mustParse(t *testing.T, src string) *ast.Program {
	t.Helper()
	p, err := Parse(src)
	if err != nil {
		t.Fatalf("Parse(%q): %v", src, err)
	}
	return p
}

func TestParseClauses(t *testing.T) {
	p := mustParse(t, `
% a comment: p(x).
edge(1, -2). edge(a, b_1).   edge(0,x9)
.
path(X, Z) :- edge(X, Y), not blocked(Y), path(Y, Z), X != Z, 3<=Y, Y>-1.
?- path(a, _).
?-path(_, _).
`)
	var got []string
	for _, r := range p.Rules {
		got = append(got, r.String())
	}
	want := []string{
		"edge(1, -2).",
		"edge(a, b_1).",
		"edge(0, x9).",
		"path(X, Z) :- edge(X, Y), not blocked(Y), path(Y, Z), X != Z, 3 <= Y, Y > -1.",
	}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("rules:\n got %q\nwant %q", got, want)
	}
	if len(p.Queries) != 2 || p.Queries[0].String() != "path(a, _)" || p.Queries[1].String() != "path(_, _)" {
		t.Errorf("queries = %v", p.Queries)
	}
	if p.Rules[3].Line != 5 {
		t.Errorf("line = %d, want 5", p.Rules[3].Line)
	}
}

func TestAnonymousVariablesAreDistinct(t *testing.T) {
	p := mustParse(t, "p(X) :- q(_, _, X).")
	args := p.Rules[0].Body[0].Atom.Args
	if args[0] == args[1] || !args[0].IsAnon() || !args[1].IsAnon() || args[2].IsAnon() {
		t.Errorf("args = %v", args)
	}
}

func TestLexingEdgeCases(t *testing.T) {
	// "X<-1" is X, <, -1; keyword prefix identifiers are ordinary names.
	p := mustParse(t, "p(X) :- q(X), X<-1, not_x(X), nothing(X).")
	body := p.Rules[0].Body
	if body[1].Kind != ast.Comparison || body[1].Op != ast.Lt || body[1].Right.Value != ast.Int(-1) {
		t.Errorf("comparison = %v", body[1])
	}
	if body[2].Kind != ast.Positive || body[2].Atom.Name != "not_x" || body[3].Atom.Name != "nothing" {
		t.Errorf("body = %v", body)
	}
	p = mustParse(t, "r(X):-s(X).")
	if len(p.Rules) != 1 {
		t.Error("':-' without spaces")
	}
}

func TestComparisonBetweenConstants(t *testing.T) {
	p := mustParse(t, "p(X) :- q(X), 5 < abc, abc >= X.")
	b := p.Rules[0].Body
	if b[1].Left.Value != ast.Int(5) || b[1].Right.Value != ast.Sym("abc") || b[2].Op != ast.Ge {
		t.Errorf("body = %v", b)
	}
}

func TestEmptyAndCommentOnly(t *testing.T) {
	for _, src := range []string{"", "  \n\t", "% only a comment", "%x\n%y"} {
		p := mustParse(t, src)
		if len(p.Rules) != 0 || len(p.Queries) != 0 {
			t.Errorf("%q: %v", src, p)
		}
	}
}

func TestSyntaxErrors(t *testing.T) {
	for _, src := range []string{
		"p(", "p(a)", "p(a) :- .", "p() .", "?- p(a)", "p(a) :- q(b) r(c).",
		"p(X) :- X.", "P(a).", "p(a) :- not X < 3.", "p(_a).", "p(a) $ .",
	} {
		_, err := Parse(src)
		var se *SyntaxError
		if !errors.As(err, &se) {
			t.Errorf("Parse(%q) err = %v, want SyntaxError", src, err)
		}
	}
}

func TestErrorPosition(t *testing.T) {
	_, err := Parse("p(a).\nq(b) r.")
	var se *SyntaxError
	if !errors.As(err, &se) || se.Line != 2 || se.Col != 6 {
		t.Errorf("err = %v", err)
	}
}
