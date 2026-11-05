package syntax

import (
	"reflect"
	"strings"
	"testing"
)

func kinds(t *testing.T, src string) []TokenKind {
	t.Helper()
	toks, err := Lex([]byte(src), NewInterner())
	if err != nil {
		t.Fatalf("Lex(%q): %v", src, err)
	}
	var ks []TokenKind
	for _, tok := range toks {
		ks = append(ks, tok.Kind)
	}
	return ks
}

func TestLexSymbolsLongestMatch(t *testing.T) {
	got := kinds(t, ";; ; -> - :: <= < >= > && || = ( ) [ ] , + * /")
	want := []TokenKind{SemiSemi, Semi, Arrow, Minus, ColonColon, Le, Lt, Ge, Gt,
		AndAnd, OrOr, Eq, LParen, RParen, LBrack, RBrack, Comma, Plus, Star, Slash, EOF}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestLexNoWhitespaceNeeded(t *testing.T) {
	got := kinds(t, "f(x)->1;;[1;2]")
	want := []TokenKind{Ident, LParen, Ident, RParen, Arrow, IntLit, SemiSemi,
		LBrack, IntLit, Semi, IntLit, RBrack, EOF}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestLexKeywordsAndIdentifiers(t *testing.T) {
	got := kinds(t, "let rec in fun if then else true false letx funny inx x1 aB_c d")
	want := []TokenKind{KwLet, KwRec, KwIn, KwFun, KwIf, KwThen, KwElse, KwTrue, KwFalse,
		Ident, Ident, Ident, Ident, Ident, Ident, EOF}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestLexInterning(t *testing.T) {
	in := NewInterner()
	toks, err := Lex([]byte("a b a c b"), in)
	if err != nil {
		t.Fatal(err)
	}
	var ids []int32
	for _, tok := range toks[:5] {
		ids = append(ids, tok.ID)
	}
	if want := []int32{0, 1, 0, 2, 1}; !reflect.DeepEqual(ids, want) {
		t.Errorf("ids = %v, want %v", ids, want)
	}
	if in.Len() != 3 || in.Name(2) != "c" {
		t.Errorf("interner state wrong: len=%d name(2)=%q", in.Len(), in.Name(2))
	}
}

func TestLexLongInteger(t *testing.T) {
	got := kinds(t, "123456789012345678901234567890")
	if !reflect.DeepEqual(got, []TokenKind{IntLit, EOF}) {
		t.Errorf("got %v", got)
	}
}

func TestLexWhitespaceAndEmpty(t *testing.T) {
	if got := kinds(t, " \t\r\n "); !reflect.DeepEqual(got, []TokenKind{EOF}) {
		t.Errorf("got %v", got)
	}
}

func TestLexErrors(t *testing.T) {
	for _, src := range []string{"a : b", "a & b", "a | b", "a # b", "X"} {
		_, err := Lex([]byte(src), NewInterner())
		if err == nil {
			t.Errorf("Lex(%q) succeeded, want error", src)
		} else if !strings.Contains(err.Error(), "syntax error") {
			t.Errorf("unexpected error text %q", err)
		}
	}
}
