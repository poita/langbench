package datalog

import "testing"

func kinds(t *testing.T, src string) []tokKind {
	t.Helper()
	toks, err := lex([]byte(src))
	if err != nil {
		t.Fatalf("lex(%q): %v", src, err)
	}
	var ks []tokKind
	for _, tok := range toks {
		ks = append(ks, tok.kind)
	}
	return ks
}

func TestLexLongestMatch(t *testing.T) {
	got := kinds(t, "X<-1 a<=b :- ?- != >= not nothing not_x _")
	want := []tokKind{tVar, tLT, tInt, tIdent, tLE, tIdent, tImplies, tQuery, tNE, tGE,
		tNot, tIdent, tIdent, tAnon, tEOF}
	if len(got) != len(want) {
		t.Fatalf("got %v want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("token %d: got %v want %v", i, got[i], want[i])
		}
	}
}

func TestLexCommentsAndPositions(t *testing.T) {
	toks, err := lex([]byte("% comment\n  p(1). % tail\n"))
	if err != nil {
		t.Fatal(err)
	}
	if toks[0].kind != tIdent || toks[0].line != 2 || toks[0].col != 3 {
		t.Errorf("unexpected first token %+v", toks[0])
	}
}

func TestLexNegativeInteger(t *testing.T) {
	toks, _ := lex([]byte("p(-12, 0)"))
	if toks[2].kind != tInt || toks[2].num != -12 {
		t.Errorf("got %+v", toks[2])
	}
}

func TestLexErrors(t *testing.T) {
	for _, src := range []string{"p(#).", "_x", "p(-).", "a ! b", "a : b"} {
		if _, err := lex([]byte(src)); err == nil {
			t.Errorf("lex(%q) succeeded, want error", src)
		}
	}
}
