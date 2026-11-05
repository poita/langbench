package datalog

import (
	"errors"
	"testing"
)

func TestParseConstantOrder(t *testing.T) {
	prog, err := Parse([]byte("p(b). p(a0). p(a). p(10). p(-3). p(2). p(a_). p(aa)."))
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, c := range prog.Consts {
		got = append(got, c.String())
	}
	want := []string{"-3", "2", "10", "a", "a0", "a_", "aa", "b"}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v want %v", got, want)
		}
	}
	// Terms must refer to ranks.
	r := prog.Rules[0] // p(b)
	if prog.Consts[r.Head.Args[0].Index] != Sym("b") {
		t.Errorf("head constant not renumbered")
	}
}

func TestParsePredicatesByArity(t *testing.T) {
	prog, err := Parse([]byte("r(1). r(1, 2). ?- r(X)."))
	if err != nil {
		t.Fatal(err)
	}
	if len(prog.Preds) != 2 {
		t.Fatalf("want 2 predicates, got %v", prog.Preds)
	}
}

func TestParseVariables(t *testing.T) {
	prog, err := Parse([]byte("p(X, Y) :- q(X, _), r(_, Y), X < Y. p(X, Y) :- q(Y, X)."))
	if err != nil {
		t.Fatal(err)
	}
	if prog.Rules[0].NumVars != 4 {
		t.Errorf("rule 0 NumVars = %d, want 4", prog.Rules[0].NumVars)
	}
	if prog.Rules[1].NumVars != 2 {
		t.Errorf("rule 1 NumVars = %d, want 2 (scoped per clause)", prog.Rules[1].NumVars)
	}
	body := prog.Rules[0].Body
	if len(body) != 3 || body[2].Kind != Comparison || body[2].Op != OpLt {
		t.Errorf("unexpected body %+v", body)
	}
}

func TestParseLiterals(t *testing.T) {
	prog, err := Parse([]byte("p(X) :- q(X), not r(X), X != a, 3 <= X, X >= 1, X > 0, X = X."))
	if err != nil {
		t.Fatal(err)
	}
	kindsWant := []LiteralKind{Positive, Negative, Comparison, Comparison, Comparison, Comparison, Comparison}
	opsWant := []CmpOp{0, 0, OpNe, OpLe, OpGe, OpGt, OpEq}
	for i, l := range prog.Rules[0].Body {
		if l.Kind != kindsWant[i] || (l.Kind == Comparison && l.Op != opsWant[i]) {
			t.Errorf("literal %d = %+v", i, l)
		}
	}
}

func TestParseSyntaxErrors(t *testing.T) {
	for _, src := range []string{"p(1)", "p(1,).", "p :- q(1).", "p(1) :- .", "?- p(1)", "p(X) :- not X.", "p(1) q(2)."} {
		_, err := Parse([]byte(src))
		var se *SyntaxError
		if !errors.As(err, &se) {
			t.Errorf("Parse(%q) = %v, want SyntaxError", src, err)
		}
	}
}

func TestParseEmpty(t *testing.T) {
	for _, src := range []string{"", "  \n\t", "% only a comment"} {
		prog, err := Parse([]byte(src))
		if err != nil || len(prog.Rules)+len(prog.Queries) != 0 {
			t.Errorf("Parse(%q) = %v, %v", src, prog, err)
		}
	}
}
