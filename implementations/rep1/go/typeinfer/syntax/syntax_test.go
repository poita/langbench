package syntax

import (
	"reflect"
	"strings"
	"testing"
)

func lex(t *testing.T, src string) []TokenKind {
	t.Helper()
	l := NewLexer(src)
	var out []TokenKind
	for {
		tok, err := l.Next()
		if err != nil {
			t.Fatal(err)
		}
		if tok.Kind == TokEOF {
			return out
		}
		out = append(out, tok.Kind)
	}
}

func TestLexerLongestMatch(t *testing.T) {
	got := lex(t, ";;;->-:: <=>=&&||<>=")
	want := []TokenKind{TokDSemi, TokSemi, TokArrow, TokMinus, TokCons, TokLe, TokGe, TokAnd, TokOr, TokLt, TokGe}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestLexerIdentifiersAndKeywords(t *testing.T) {
	got := lex(t, "let letx rec in inx fun funny if then else true false x_1 aB")
	want := []TokenKind{TokLet, TokIdent, TokRec, TokIn, TokIdent, TokFun, TokIdent, TokIf, TokThen, TokElse, TokTrue, TokFalse, TokIdent, TokIdent}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestLexerBadCharacter(t *testing.T) {
	l := NewLexer("  #")
	if _, err := l.Next(); err == nil {
		t.Error("expected an error")
	}
}

// show renders an expression fully parenthesised.
func show(e Expr) string {
	switch e := e.(type) {
	case *IntLit:
		return e.Text
	case *BoolLit:
		if e.Value {
			return "true"
		}
		return "false"
	case *UnitLit:
		return "()"
	case *Var:
		return e.Name
	case *Lam:
		return "(fun " + e.Param + " -> " + show(e.Body) + ")"
	case *App:
		return "(" + show(e.Fn) + " " + show(e.Arg) + ")"
	case *Let:
		kw := "let "
		if e.Rec {
			kw = "let rec "
		}
		return "(" + kw + e.Name + " = " + show(e.Value) + " in " + show(e.Body) + ")"
	case *If:
		return "(if " + show(e.Cond) + " then " + show(e.Then) + " else " + show(e.Else) + ")"
	case *Tuple:
		return "(" + join(e.Elems, ", ") + ")"
	case *List:
		return "[" + join(e.Elems, "; ") + "]"
	case *Cons:
		return "(" + show(e.Head) + " :: " + show(e.Tail) + ")"
	case *BinOp:
		return "(" + show(e.L) + " " + e.Op.String() + " " + show(e.R) + ")"
	}
	return "?"
}

func join(es []Expr, sep string) string {
	parts := make([]string, len(es))
	for i, e := range es {
		parts[i] = show(e)
	}
	return strings.Join(parts, sep)
}

func TestPrecedence(t *testing.T) {
	tests := []struct{ in, want string }{
		{"f x + g y * 2", "((f x) + ((g y) * 2))"},
		{"1 :: f x :: l", "(1 :: ((f x) :: l))"},
		{"a < b && c", "((a < b) && c)"},
		{"a || b && c || d", "((a || (b && c)) || d)"},
		{"a - b - c", "((a - b) - c)"},
		{"a / b * c", "((a / b) * c)"},
		{"fun x -> x + 1", "(fun x -> (x + 1))"},
		{"fun x y -> x", "(fun x -> (fun y -> x))"},
		{"if a then b else c + 1", "(if a then b else (c + 1))"},
		{"1 + 2 :: [] ", "((1 + 2) :: [])"},
		{"f x y", "((f x) y)"},
		{"(fun x -> x, 1)", "((fun x -> x), 1)"},
		{"[fun x -> x; fun y -> 1]", "[(fun x -> x); (fun y -> 1)]"},
		{"(let y = 1 in y, 2)", "((let y = 1 in y), 2)"},
		{"(1, 2, 3)", "(1, 2, 3)"},
		{"()", "()"},
		{"[]", "[]"},
		{"(x)", "x"},
		{"let f x y = e in f", "(let f = (fun x -> (fun y -> e)) in f)"},
		{"let rec f x = f x in f", "(let rec f = (fun x -> (f x)) in f)"},
		{"123456789012345678901234567890", "123456789012345678901234567890"},
	}
	for _, tc := range tests {
		e, err := ParseExpr(tc.in)
		if err != nil {
			t.Errorf("%q: %v", tc.in, err)
			continue
		}
		if got := show(e); got != tc.want {
			t.Errorf("%q: got %s, want %s", tc.in, got, tc.want)
		}
	}
}

func TestParseProgram(t *testing.T) {
	decls, err := ParseProgram("let x = 1;; x;;let rec f n = f n;;\n(let y = 2 in y);;")
	if err != nil {
		t.Fatal(err)
	}
	if len(decls) != 4 {
		t.Fatalf("got %d decls", len(decls))
	}
	if decls[0].Name != "x" || decls[0].Rec || !decls[0].IsBinding() {
		t.Errorf("decl 0: %+v", decls[0])
	}
	if decls[1].IsBinding() {
		t.Errorf("decl 1 should be a bare expression")
	}
	if decls[2].Name != "f" || !decls[2].Rec {
		t.Errorf("decl 2: %+v", decls[2])
	}
	if decls[3].IsBinding() {
		t.Errorf("decl 3 should be a bare expression")
	}
}

func TestParseEmpty(t *testing.T) {
	for _, src := range []string{"", "  \n\t "} {
		decls, err := ParseProgram(src)
		if err != nil || len(decls) != 0 {
			t.Errorf("%q: %v %v", src, decls, err)
		}
	}
}

func TestParseErrors(t *testing.T) {
	for _, src := range []string{
		"let = 1;;", "let rec f = fun x -> x;;", "1 +;;", "(1, ;;", "let x = 1", "fun -> x;;", "[1; ;;", "1 # 2;;",
		"let x = 1 in x;;",
	} {
		if _, err := ParseProgram(src); err == nil {
			t.Errorf("%q: expected error", src)
		}
	}
}

func TestDeepNesting(t *testing.T) {
	n := 4000
	src := strings.Repeat("(", n) + "1" + strings.Repeat(")", n) + ";;"
	if _, err := ParseProgram(src); err != nil {
		t.Fatal(err)
	}
	src = "f" + strings.Repeat(" x", 5000) + ";;"
	if _, err := ParseProgram(src); err != nil {
		t.Fatal(err)
	}
}
