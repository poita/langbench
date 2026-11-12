package parser

import (
	"testing"

	"langvm/ast"
	"langvm/lexer"
)

func parse(t *testing.T, lines ...string) (*ast.Module, error) {
	t.Helper()
	toks, lerr := lexer.Lex(lines)
	if lerr != nil {
		t.Fatalf("lex: %v", lerr)
	}
	m, err := Parse("m", toks)
	if err != nil {
		return nil, err
	}
	return m, nil
}

func TestParsesItems(t *testing.T) {
	src := []string{
		"use util as u;",
		"pub struct P<A, B> { x: A, y: [B], }",
		"enum E { A, B(Int, Str), }",
		"trait T { fn f(self) -> Int; fn g(self, a: Int) { } }",
		"impl<X: T + Eq> T for [X] { fn f(self) -> Int { 1 } }",
		"fn main() { let (a, b) = (1, 2); }",
	}
	m, err := parse(t, src...)
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Items) != 6 {
		t.Fatalf("got %d items", len(m.Items))
	}
}

func TestParseErrors(t *testing.T) {
	cases := []struct{ src, want string }{
		{"fn f( {", "error: parse at 1:7"},
		{"fn main() { 1 < 2 < 3; }", "error: parse at 1:19"},
		{"struct S<T: Eq> { }", "error: parse at 1:11"},
		{"fn main() { | | 8; }", "error: parse at 1:15"},
		{"fn f(x: (Int)) {}", "error: parse at 1:13"},
		{"fn main() { f(1) 2 }", "error: parse at 1:18"},
		{"pub impl X for Int {}", "error: parse at 1:5"},
		{"fn main() { match x { [.., a] -> 1 } }", "error: parse at 1:26"},
		{"fn f(x: Option<Int>>) {}", "error: parse at 1:19"},
		{"fn main() {", "error: parse at 1:12"},
	}
	for _, c := range cases {
		_, err := parse(t, c.src)
		if err == nil || err.Error() != c.want {
			t.Errorf("%q: got %v, want %s", c.src, err, c.want)
		}
	}
}

func TestStatementEndsWithoutSemicolonAfterIf(t *testing.T) {
	m, err := parse(t, "fn main() { if a { b() } c(); }")
	if err != nil {
		t.Fatal(err)
	}
	body := m.Items[0].(*ast.FnDecl).Body
	if len(body.Stmts) != 2 {
		t.Fatalf("got %d statements, want 2", len(body.Stmts))
	}
}

func TestNestedTypeArgs(t *testing.T) {
	if _, err := parse(t, "fn f(x: A<B<C<D>>>, y: A<B<C>>) {}"); err != nil {
		t.Fatal(err)
	}
}
