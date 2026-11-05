package lexer

import (
	"testing"

	"langvm/diag"
)

func kinds(t *testing.T, src string) []Token {
	t.Helper()
	toks, err := Lex([]rune(src))
	if err != nil {
		t.Fatalf("Lex(%q): %v", src, err)
	}
	return toks
}

func TestNumbers(t *testing.T) {
	cases := []struct {
		src  string
		kind Kind
		i    int64
		f    float64
	}{
		{"42", IntLit, 42, 0},
		{"1_000", IntLit, 1000, 0},
		{"007", IntLit, 7, 0},
		{"0xFF_ff", IntLit, 65535, 0},
		{"0b1_0", IntLit, 2, 0},
		{"9223372036854775807", IntLit, 9223372036854775807, 0},
		{"1.5", FloatLit, 0, 1.5},
		{"1_.5", FloatLit, 0, 1.5},
		{"1e1_0", FloatLit, 0, 1e10},
		{"2.5E-3", FloatLit, 0, 2.5e-3},
		{"1e400", FloatLit, 0, 0}, // +Inf, checked separately
	}
	for _, c := range cases {
		toks := kinds(t, c.src)
		if len(toks) != 2 || toks[0].Kind != c.kind {
			t.Errorf("%q: got %v", c.src, toks)
			continue
		}
		if c.kind == IntLit && toks[0].Int != c.i {
			t.Errorf("%q: int %d, want %d", c.src, toks[0].Int, c.i)
		}
		if c.kind == FloatLit && c.src != "1e400" && toks[0].Float != c.f {
			t.Errorf("%q: float %v, want %v", c.src, toks[0].Float, c.f)
		}
	}
}

func TestNumberBoundaries(t *testing.T) {
	// `1.` is an integer then a dot; `0..3` is int, `..`, int; `1e` is int, ident.
	check := func(src string, want ...Kind) {
		t.Helper()
		toks := kinds(t, src)
		if len(toks)-1 != len(want) {
			t.Fatalf("%q: got %d tokens", src, len(toks)-1)
		}
		for i, k := range want {
			if toks[i].Kind != k {
				t.Errorf("%q token %d: kind %d, want %d", src, i, toks[i].Kind, k)
			}
		}
	}
	check("1.", IntLit, Dot)
	check("0..3", IntLit, DotDot, IntLit)
	check("1e", IntLit, Ident)
	check("1e_5", IntLit, Ident)
	check("0X1", IntLit, Ident)
	check("123abc", IntLit, Ident)
}

func TestErrors(t *testing.T) {
	cases := []struct {
		src  string
		kind diag.Kind
		line int
		col  int
	}{
		{"  `", diag.BadToken, 1, 3},
		{"#x", diag.BadToken, 1, 1},
		{"0x", diag.BadToken, 1, 1},
		{"0x_1", diag.BadToken, 1, 1},
		{"0b2", diag.BadToken, 1, 1},
		{"é", diag.BadToken, 1, 1},
		{"9223372036854775808", diag.IntRange, 1, 1},
		{"0xFFFFFFFFFFFFFFFF", diag.IntRange, 1, 1},
		{`"ab`, diag.Unterminated, 1, 1},
		{"\"ab\ncd\"", diag.Unterminated, 1, 1},
		{"'ab'", diag.Unterminated, 1, 1},
		{"''", diag.Unterminated, 1, 1},
		{`"ab\q`, diag.BadEscape, 1, 4},
		{`'\q'`, diag.BadEscape, 1, 2},
		{`"\u{110000}"`, diag.BadEscape, 1, 2},
		{`"\u{D800}"`, diag.BadEscape, 1, 2},
		{`"\u{}"`, diag.BadEscape, 1, 2},
		{`"\u{41"`, diag.BadEscape, 1, 2},
		{"/* /* */", diag.Unterminated, 1, 1},
		{"x\n  /* open", diag.Unterminated, 2, 3},
	}
	for _, c := range cases {
		_, err := Lex([]rune(c.src))
		if err == nil || err.Kind != c.kind || err.Pos.Line != c.line || err.Pos.Col != c.col {
			t.Errorf("%q: got %v, want %s at %d:%d", c.src, err, c.kind, c.line, c.col)
		}
	}
}

func TestEscapesAndStrings(t *testing.T) {
	toks := kinds(t, `"a\n\t\\\"\u{1F600}\0"`)
	want := []rune{'a', '\n', '\t', '\\', '"', 0x1F600, 0}
	got := toks[0].Str
	if string(got) != string(want) {
		t.Fatalf("got %q, want %q", string(got), string(want))
	}
	c := kinds(t, `'\''`)[0]
	if c.Kind != CharLit || c.Int != '\'' {
		t.Fatalf("char escape: %+v", c)
	}
}

func TestOperatorsAndPositions(t *testing.T) {
	toks := kinds(t, "a >>= b #[ || | ++ :: -> .. _ _x")
	want := []Kind{Ident, Shr, Assign, Ident, HashBracket, OrOr, Pipe, PlusPlus, ColonColon, Arrow, DotDot, Underscore, Ident}
	for i, k := range want {
		if toks[i].Kind != k {
			t.Errorf("token %d: kind %d, want %d", i, toks[i].Kind, k)
		}
	}
	toks = kinds(t, "ab\n\tcd // c\n  /* x\ny */ ef")
	pos := []diag.Pos{{Line: 1, Col: 1}, {Line: 2, Col: 2}, {Line: 4, Col: 6}, {Line: 4, Col: 8}}
	for i, p := range pos {
		if toks[i].Pos != p {
			t.Errorf("token %d at %v, want %v", i, toks[i].Pos, p)
		}
	}
}

func TestIdentifiers(t *testing.T) {
	long := make([]rune, 201)
	for i := range long {
		long[i] = 'a'
	}
	if _, err := Lex(long); err == nil || err.Kind != diag.BadToken {
		t.Fatalf("201-char identifier: %v", err)
	}
	if _, err := Lex(long[:200]); err != nil {
		t.Fatalf("200-char identifier: %v", err)
	}
	if k := kinds(t, "while whilex")[0].Kind; k != KwWhile {
		t.Fatalf("keyword not recognised")
	}
	if !IsKeyword("impl") || IsKeyword("Self") {
		t.Fatalf("IsKeyword wrong")
	}
}
