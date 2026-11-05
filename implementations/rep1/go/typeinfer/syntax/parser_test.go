package syntax

import (
	"fmt"
	"strings"
	"testing"
)

// sexp renders an expression as a fully parenthesised S-expression so tests
// can check precedence and associativity.
func sexp(p *Program, in *Interner, e int32) string {
	n := &p.Nodes[e]
	switch n.Kind {
	case KInt:
		return "int"
	case KBool:
		if n.A == 1 {
			return "true"
		}
		return "false"
	case KUnit:
		return "()"
	case KVar:
		return in.Name(n.Name)
	case KFun:
		return fmt.Sprintf("(fun %s %s)", in.Name(n.Name), sexp(p, in, n.A))
	case KApp:
		return fmt.Sprintf("(%s %s)", sexp(p, in, n.A), sexp(p, in, n.B))
	case KLet, KLetRec:
		kw := "let"
		if n.Kind == KLetRec {
			kw = "letrec"
		}
		return fmt.Sprintf("(%s %s %s %s)", kw, in.Name(n.Name), sexp(p, in, n.A), sexp(p, in, n.B))
	case KIf:
		return fmt.Sprintf("(if %s %s %s)", sexp(p, in, n.A), sexp(p, in, n.B), sexp(p, in, n.C))
	case KTuple, KList:
		var parts []string
		for _, k := range p.Children(n) {
			parts = append(parts, sexp(p, in, k))
		}
		name := "tuple"
		if n.Kind == KList {
			name = "list"
		}
		return "(" + name + " " + strings.Join(parts, " ") + ")"
	case KCons:
		return fmt.Sprintf("(:: %s %s)", sexp(p, in, n.A), sexp(p, in, n.B))
	case KBinop:
		ops := map[Op]string{OpAdd: "+", OpSub: "-", OpMul: "*", OpDiv: "/", OpEq: "=",
			OpLt: "<", OpGt: ">", OpLe: "<=", OpGe: ">=", OpAnd: "&&", OpOr: "||"}
		return fmt.Sprintf("(%s %s %s)", ops[n.Op], sexp(p, in, n.A), sexp(p, in, n.B))
	}
	return "?"
}

func parseExpr(t *testing.T, src string) string {
	t.Helper()
	in := NewInterner()
	p, err := Parse([]byte(src+";;"), in)
	if err != nil {
		t.Fatalf("Parse(%q): %v", src, err)
	}
	if len(p.Decls) != 1 || p.Decls[0].Kind != DeclExpr {
		t.Fatalf("Parse(%q): decls = %+v", src, p.Decls)
	}
	return sexp(p, in, p.Decls[0].Expr)
}

func TestPrecedenceAndAssociativity(t *testing.T) {
	tests := []struct{ src, want string }{
		{"f x + g y * 2", "(+ (f x) (* (g y) int))"},
		{"1 :: f x :: l", "(:: int (:: (f x) l))"},
		{"a < b && c", "(&& (< a b) c)"},
		{"a || b && c || d", "(|| (|| a (&& b c)) d)"},
		{"a - b - c", "(- (- a b) c)"},
		{"a / b * c", "(* (/ a b) c)"},
		{"f a b c", "(((f a) b) c)"},
		{"1 + 2 :: l", "(:: (+ int int) l)"},
		{"a :: b = c", "(= (:: a b) c)"},
		{"fun x -> x + 1", "(fun x (+ x int))"},
		{"fun x y -> x", "(fun x (fun y x))"},
		{"if a then b else c + 1", "(if a b (+ c int))"},
		{"if c then fun x -> x else fun y -> y", "(if c (fun x x) (fun y y))"},
	}
	for _, tc := range tests {
		if got := parseExpr(t, tc.src); got != tc.want {
			t.Errorf("%q: got %s, want %s", tc.src, got, tc.want)
		}
	}
}

func TestBracketedForms(t *testing.T) {
	tests := []struct{ src, want string }{
		{"()", "()"},
		{"(x)", "x"},
		{"(x, y, z)", "(tuple x y z)"},
		{"(fun x -> x, 1)", "(tuple (fun x x) int)"},
		{"[fun x -> x; fun y -> 1]", "(list (fun x x) (fun y int))"},
		{"(let y = 1 in y, 2)", "(tuple (let y int y) int)"},
		{"[]", "(list )"},
		{"[1]", "(list int)"},
		{"[1; 2; 3]", "(list int int int)"},
		{"((1, 2), 3)", "(tuple (tuple int int) int)"},
	}
	for _, tc := range tests {
		if got := parseExpr(t, tc.src); got != tc.want {
			t.Errorf("%q: got %s, want %s", tc.src, got, tc.want)
		}
	}
}

func TestLetForms(t *testing.T) {
	tests := []struct{ src, want string }{
		{"let x = 1 in x", "(let x int x)"},
		{"let f x y = x in f", "(let f (fun x (fun y x)) f)"},
		{"let rec f x = f x in f", "(letrec f (fun x (f x)) f)"},
		{"let x = 1 in let y = 2 in x", "(let x int (let y int x))"},
	}
	for _, tc := range tests {
		if got := parseExpr(t, "("+tc.src+")"); got != tc.want {
			t.Errorf("%q: got %s, want %s", tc.src, got, tc.want)
		}
	}
}

func TestDeclarations(t *testing.T) {
	in := NewInterner()
	p, err := Parse([]byte("let a = 1;; let rec f x y = f y x;; a;;  let g x = x;;"), in)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Decls) != 4 {
		t.Fatalf("got %d decls", len(p.Decls))
	}
	wantKinds := []DeclKind{DeclLet, DeclLetRec, DeclExpr, DeclLet}
	for i, d := range p.Decls {
		if d.Kind != wantKinds[i] {
			t.Errorf("decl %d kind = %v, want %v", i, d.Kind, wantKinds[i])
		}
	}
	if got := sexp(p, in, p.Decls[1].Expr); got != "(fun x (fun y ((f y) x)))" {
		t.Errorf("let rec rhs = %s", got)
	}
	if in.Name(p.Decls[3].Name) != "g" {
		t.Errorf("name = %q", in.Name(p.Decls[3].Name))
	}
}

func TestEmptyProgram(t *testing.T) {
	for _, src := range []string{"", "  \n\t "} {
		p, err := Parse([]byte(src), NewInterner())
		if err != nil || len(p.Decls) != 0 {
			t.Errorf("Parse(%q) = %d decls, %v", src, len(p.Decls), err)
		}
	}
}

func TestSyntaxErrorKeepsEarlierDecls(t *testing.T) {
	p, err := Parse([]byte("let a = 1;; let = ;; let b = 2;;"), NewInterner())
	if err == nil {
		t.Fatal("expected error")
	}
	if _, ok := err.(*Error); !ok {
		t.Errorf("error type %T", err)
	}
	if len(p.Decls) != 1 {
		t.Errorf("got %d decls before the error, want 1", len(p.Decls))
	}
}

func TestDeepNesting(t *testing.T) {
	const n = 3000
	src := strings.Repeat("(", n) + "1" + strings.Repeat(")", n) + ";;"
	if _, err := Parse([]byte(src), NewInterner()); err != nil {
		t.Fatal(err)
	}
	src = "1" + strings.Repeat(" :: 1", 2000) + ";;"
	if _, err := Parse([]byte(src), NewInterner()); err != nil {
		t.Fatal(err)
	}
}
