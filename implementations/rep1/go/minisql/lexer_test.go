package minisql

import "testing"

func TestTokenize(t *testing.T) {
	toks := tokenize("SeLeCt a1, 'it''s' -- comment ; x\n <= <> != == 007")
	want := []token{
		{kind: tKeyword, text: "select"}, {kind: tIdent, text: "a1"}, {kind: tOp, text: ","},
		{kind: tString, text: "it's"}, {kind: tOp, text: "<="}, {kind: tOp, text: "<>"},
		{kind: tOp, text: "!="}, {kind: tOp, text: "=="}, {kind: tInt, text: "007", ival: 7},
	}
	if len(toks) != len(want) {
		t.Fatalf("got %d tokens %v, want %d", len(toks), toks, len(want))
	}
	for i := range want {
		if toks[i] != want[i] {
			t.Errorf("token %d = %+v, want %+v", i, toks[i], want[i])
		}
	}
}

func TestTokenizeInvalid(t *testing.T) {
	for _, src := range []string{`"x"`, "@", "é", `\`, "$"} {
		toks := tokenize(src)
		bad := false
		for _, tk := range toks {
			bad = bad || tk.kind == tInvalid
		}
		if !bad {
			t.Errorf("%q: expected an invalid token, got %v", src, toks)
		}
	}
	if toks := tokenize("'abc; def"); len(toks) != 1 || toks[0].kind != tUnterminated {
		t.Errorf("unterminated string: got %v", toks)
	}
}

func TestSplitStatements(t *testing.T) {
	got := splitStatements(tokenize(";; select 1; -- c\n select ';' ; ; select 2"))
	if len(got) != 3 {
		t.Fatalf("got %d statements, want 3", len(got))
	}
	if n := len(splitStatements(tokenize("  -- only a comment\n;;"))); n != 0 {
		t.Errorf("got %d statements, want 0", n)
	}
}

func TestDashDashIsAlwaysComment(t *testing.T) {
	if toks := tokenize("1--5"); len(toks) != 1 {
		t.Errorf("got %v, want a single token", toks)
	}
}
