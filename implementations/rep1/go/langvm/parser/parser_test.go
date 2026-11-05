package parser

import (
	"testing"

	"langvm/ast"
	"langvm/diag"
	"langvm/lexer"
)

func parse(t *testing.T, src string) (*ast.Module, *diag.Error) {
	t.Helper()
	toks, lerr := lexer.Lex([]rune(src))
	if lerr != nil {
		t.Fatalf("lex error: %v", lerr)
	}
	return Parse("m", toks)
}

func mustParse(t *testing.T, src string) *ast.Module {
	t.Helper()
	m, err := parse(t, src)
	if err != nil {
		t.Fatalf("parse %q: %v", src, err)
	}
	return m
}

func bodyOf(t *testing.T, m *ast.Module) *ast.Block {
	return m.Items[0].(*ast.FnDecl).Body
}

func TestPrecedence(t *testing.T) {
	// bitwise operators bind tighter than comparison: a & b == c is (a & b) == c
	m := mustParse(t, "fn f() { a & b == c }")
	b := bodyOf(t, m).Tail.(*ast.Binary)
	if b.Op != ast.OpEq {
		t.Fatalf("top operator %v, want ==", b.Op)
	}
	if l, ok := b.L.(*ast.Binary); !ok || l.Op != ast.OpBitAnd {
		t.Fatalf("left is not &")
	}
	m = mustParse(t, "fn f() { 1 + 2 * 3 - 4 }")
	top := bodyOf(t, m).Tail.(*ast.Binary)
	if top.Op != ast.OpSub {
		t.Fatalf("top operator %v, want -", top.Op)
	}
}

func TestChainedComparisonIsError(t *testing.T) {
	_, err := parse(t, "fn f() { a < b < c }")
	if err == nil || err.Kind != diag.Parse || err.Pos.Col != 16 {
		t.Fatalf("got %v", err)
	}
}

func TestParenthesesAreTransparent(t *testing.T) {
	m := mustParse(t, "fn f() { (a + b) * c }")
	mul := bodyOf(t, m).Tail.(*ast.Binary)
	if pos := mul.Position(); pos.Col != 11 {
		t.Fatalf("position %v: parentheses must not count", pos)
	}
}

func TestIfStatementContinuation(t *testing.T) {
	m := mustParse(t, "fn f() { if c { g() } else { h() }\n(1, 2);\n}")
	stmts := bodyOf(t, m).Stmts
	if len(stmts) != 1 {
		t.Fatalf("want one statement, got %d", len(stmts))
	}
	if _, ok := stmts[0].(*ast.ExprStmt).X.(*ast.Call); !ok {
		t.Fatalf("expected the tuple to be parsed as a call of the if")
	}
	m = mustParse(t, "fn f() { if c { g() }; x }")
	if len(bodyOf(t, m).Stmts) != 1 || bodyOf(t, m).Tail == nil {
		t.Fatalf("`;` should end the if statement")
	}
}

func TestTypeArgsSplitShr(t *testing.T) {
	mustParse(t, "fn f(x: A<B<C>>) -> Option<Option<Int>> { x }")
	mustParse(t, "fn f(x: A<B<C<D>>>) {}")
}

func TestLambdas(t *testing.T) {
	m := mustParse(t, "fn f() { let g = |a, b: Int| -> Int { a }; let h = || 1; }")
	st := bodyOf(t, m).Stmts[0].(*ast.LetStmt).Init.(*ast.Lambda)
	if len(st.Params) != 2 || st.Params[1].Type == nil || st.Ret == nil {
		t.Fatalf("bad lambda: %+v", st)
	}
	if _, err := parse(t, "fn f() { let g = | | 8; }"); err == nil || err.Pos.Col != 20 {
		t.Fatalf("`| |` should be a parse error at the second bar, got %v", err)
	}
}

func TestPatterns(t *testing.T) {
	mustParse(t, `fn f() { match x { _ -> 1, -3 -> 2, "s" -> 3, 'c' -> 4, true -> 5,
		(a, b) -> 6, [a, ..r] -> 7, [..] -> 8, P.{ a, b: 1, .. } -> 9, m::C(z) -> 10, V -> 11 } }`)
	for _, bad := range []string{
		"fn f() { match x { [.., a] -> 1 } }",
		"fn f() { match x { [a, .., ..] -> 1 } }",
		"fn f() { match x { (a) -> 1 } }",
		"fn f() { match x { C() -> 1 } }",
	} {
		if _, err := parse(t, bad); err == nil || err.Kind != diag.Parse {
			t.Errorf("%q: want parse error, got %v", bad, err)
		}
	}
}

func TestMatchArmCommas(t *testing.T) {
	mustParse(t, "fn f() { match x { A -> { 1 } B -> { 2 } } }")
	if _, err := parse(t, "fn f() { match x { A -> 1 B -> 2 } }"); err == nil {
		t.Fatalf("expression arm without comma must fail")
	}
}

func TestStructLiteralAndAssignment(t *testing.T) {
	m := mustParse(t, "fn f() { let p = Point.{ x: 1, y: 2 }; a[i] = 3; x = p.x; }")
	b := bodyOf(t, m)
	if _, ok := b.Stmts[0].(*ast.LetStmt).Init.(*ast.StructLit); !ok {
		t.Fatalf("not a struct literal")
	}
	if _, ok := b.Stmts[1].(*ast.AssignStmt); !ok {
		t.Fatalf("not an assignment")
	}
}

func TestItemErrors(t *testing.T) {
	cases := map[string][2]int{
		"struct S<T: Eq> {}":                 {1, 11},
		"pub impl X for Y {}":                {1, 5},
		"impl X for Y { pub fn f(self) {} }": {1, 16},
		"trait T { fn f(); }":                {1, 16},
		"fn f(":                              {1, 6},
		"fn f() {\n  let x = 1":              {2, 12},
		"fn f(x: (Int)) {}":                  {1, 13},
	}
	for src, want := range cases {
		_, err := parse(t, src)
		if err == nil || err.Kind != diag.Parse || err.Pos.Line != want[0] || err.Pos.Col != want[1] {
			t.Errorf("%q: got %v, want parse at %d:%d", src, err, want[0], want[1])
		}
	}
}

func TestDivergenceFlags(t *testing.T) {
	m := mustParse(t, "fn f() { if c { return 1; } else { return 2; } }")
	if !ast.Diverges(bodyOf(t, m).Tail) {
		t.Fatalf("if/else with returning branches must diverge")
	}
	m = mustParse(t, "fn f() { while true { return 1; } }")
	if bodyOf(t, m).Div {
		t.Fatalf("while must not diverge")
	}
}
