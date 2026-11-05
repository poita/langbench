package datalog

import (
	"errors"
	"testing"
)

func mustParse(t *testing.T, src string) *Program {
	t.Helper()
	p, err := Parse([]byte(src))
	if err != nil {
		t.Fatalf("Parse(%q): %v", src, err)
	}
	return p
}

func TestParseEmptyAndComments(t *testing.T) {
	for _, src := range []string{"", "  \n\t\r\n", "% only a comment", "% a\n% b\n"} {
		p := mustParse(t, src)
		if p.NumRules() != 0 || p.NumQueries() != 0 {
			t.Errorf("%q: expected empty program", src)
		}
	}
}

func TestParseCounts(t *testing.T) {
	p := mustParse(t, "e(1,2). e(2,3). p(X,Y) :- e(X,Y). ?- p(1,X). ?- e(X,_).")
	if p.NumRules() != 3 || p.NumQueries() != 2 {
		t.Fatalf("rules=%d queries=%d", p.NumRules(), p.NumQueries())
	}
}

func TestConstantsSortedInLanguageOrder(t *testing.T) {
	p := mustParse(t, "t(b, 5, a, -2, aa, 0, a0).")
	for i := 1; i < len(p.consts); i++ {
		if p.consts[i-1].Compare(p.consts[i]) >= 0 {
			t.Fatalf("constants not sorted: %v", p.consts)
		}
	}
	// The fact's arguments must refer to the renumbered ids.
	var got []string
	for _, a := range p.rules[0].head.args {
		got = append(got, p.consts[a.id].String())
	}
	want := []string{"b", "5", "a", "-2", "aa", "0", "a0"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("args = %v, want %v", got, want)
		}
	}
}

func TestPredicatesKeyedByArity(t *testing.T) {
	p := mustParse(t, "r(1). r(1, 2). ?- r(X, Y).")
	if len(p.preds) != 2 {
		t.Fatalf("preds = %v, want r/1 and r/2", p.preds)
	}
}

func TestLexing(t *testing.T) {
	// "X<-1" is X, <, -1 ; "<=" is one token; not_x / nothing are identifiers.
	p := mustParse(t, "p(X) :- q(X),X<-1,X<=3, X>=-4, X!=2, X>1, X=X, not_x(X), nothing(X).")
	body := p.rules[0].body
	if len(body) != 9 {
		t.Fatalf("body has %d literals, want 9", len(body))
	}
	ops := []cmpOp{opLT, opLE, opGE, opNE, opGT, opEQ}
	for i, op := range ops {
		if l := body[i+1]; l.kind != litCmp || l.op != op {
			t.Errorf("literal %d: kind=%v op=%v, want comparison %v", i+1, l.kind, l.op, op)
		}
	}
	if body[7].kind != litPos || body[8].kind != litPos {
		t.Error("not_x and nothing must be ordinary predicates")
	}
}

func TestAnonymousVariablesAreFresh(t *testing.T) {
	p := mustParse(t, "p(X) :- q(X, _, _), not r(_).")
	r := p.rules[0]
	if r.numVars != 4 {
		t.Fatalf("numVars = %d, want 4 (X and three distinct _)", r.numVars)
	}
	a := r.body[0].atom.args
	if a[1].id == a[2].id {
		t.Error("two _ share a slot")
	}
}

func TestVariablesScopedPerClause(t *testing.T) {
	p := mustParse(t, "p(X) :- q(X, Y). p(Y) :- q(Y, X).")
	if p.rules[0].numVars != 2 || p.rules[1].numVars != 2 {
		t.Error("each clause numbers its own variables from 0")
	}
}

func TestClausesShareLines(t *testing.T) {
	p := mustParse(t, "a(1).b(2).\n\n  c(3)\n.\n?-\na(X)\n.")
	if p.NumRules() != 3 || p.NumQueries() != 1 {
		t.Fatalf("rules=%d queries=%d", p.NumRules(), p.NumQueries())
	}
}

func TestSyntaxErrors(t *testing.T) {
	for _, src := range []string{
		"p(1)", "p(1,).", "p(.", "p(X) :- .", "p(X) :- q(X) r(X).",
		"p(X) :- X.", "1(2).", "p(X) :- X ! 3.", "p(1) $", "p() .",
	} {
		_, err := Parse([]byte(src))
		var se *SyntaxError
		if !errors.As(err, &se) {
			t.Errorf("Parse(%q): err = %v, want *SyntaxError", src, err)
		}
	}
}

func TestSyntaxErrorLine(t *testing.T) {
	_, err := Parse([]byte("a(1).\n\nb(2) c(3)."))
	var se *SyntaxError
	if !errors.As(err, &se) || se.Line != 3 {
		t.Fatalf("err = %v, want syntax error on line 3", err)
	}
}
