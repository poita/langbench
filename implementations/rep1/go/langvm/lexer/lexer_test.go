package lexer

import (
	"testing"
)

func kinds(t *testing.T, src string) []Kind {
	t.Helper()
	toks, err := Lex([]string{src})
	if err != nil {
		t.Fatalf("lex %q: %v", src, err)
	}
	var ks []Kind
	for _, tok := range toks {
		ks = append(ks, tok.Kind)
	}
	return ks
}

func TestTokens(t *testing.T) {
	cases := []struct {
		src  string
		want []Kind
	}{
		{"a >> b", []Kind{Ident, Shr, Ident, EOF}},
		{"#[1: 2]", []Kind{HashBracket, Int, Colon, Int, RBracket, EOF}},
		{"0..3", []Kind{Int, DotDot, Int, EOF}},
		{"1.", []Kind{Int, Dot, EOF}},
		{"1e", []Kind{Int, Ident, EOF}},
		{"1e_5", []Kind{Int, Ident, EOF}},
		{"1_.5 1e1_0", []Kind{Float, Float, EOF}},
		{"0X1", []Kind{Int, Ident, EOF}},
		{"a || b | | c", []Kind{Ident, OrOr, Ident, Pipe, Pipe, Ident, EOF}},
		{"/* a /* b */ c */ x // y", []Kind{Ident, EOF}},
		{"_ _x", []Kind{Underscore, Ident, EOF}},
	}
	for _, c := range cases {
		got := kinds(t, c.src)
		if len(got) != len(c.want) {
			t.Errorf("%q: got %v, want %v", c.src, got, c.want)
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("%q: got %v, want %v", c.src, got, c.want)
				break
			}
		}
	}
}

func TestValues(t *testing.T) {
	toks, err := Lex([]string{`0xFf 0b101 9_000 'a' '\u{1F600}' "a\n\"b" 2.5e1`})
	if err != nil {
		t.Fatal(err)
	}
	if toks[0].Int != 255 || toks[1].Int != 5 || toks[2].Int != 9000 {
		t.Errorf("bad ints: %v %v %v", toks[0].Int, toks[1].Int, toks[2].Int)
	}
	if toks[3].Int != 'a' || toks[4].Int != 0x1F600 {
		t.Errorf("bad chars")
	}
	if string(toks[5].Str) != "a\n\"b" {
		t.Errorf("bad string %q", string(toks[5].Str))
	}
	if toks[6].Float != 25 {
		t.Errorf("bad float %v", toks[6].Float)
	}
}

func TestErrors(t *testing.T) {
	cases := []struct{ src, want string }{
		{"let é = 1;", "error: bad-token at 1:5"},
		{"9223372036854775808", "error: int-range at 1:1"},
		{"0x", "error: bad-token at 1:1"},
		{"0x_1", "error: bad-token at 1:1"},
		{`"ab\q`, "error: bad-escape at 1:4"},
		{`'a\q'`, "error: unterminated at 1:1"},
		{`'\q'`, "error: bad-escape at 1:2"},
		{`"\u{D800}"`, "error: bad-escape at 1:2"},
		{`"abc`, "error: unterminated at 1:1"},
		{"x /* open", "error: unterminated at 1:3"},
		{"#x", "error: bad-token at 1:1"},
		{"''", "error: unterminated at 1:1"},
	}
	for _, c := range cases {
		_, err := Lex([]string{c.src})
		if err == nil || err.Error() != c.want {
			t.Errorf("%q: got %v, want %s", c.src, err, c.want)
		}
	}
}

func TestEOFPosition(t *testing.T) {
	toks, _ := Lex([]string{"ab", "cde"})
	if p := toks[len(toks)-1].Pos; p.Line != 2 || p.Col != 4 {
		t.Errorf("eof at %v", p)
	}
	toks, _ = Lex(nil)
	if p := toks[0].Pos; p.Line != 1 || p.Col != 1 {
		t.Errorf("empty eof at %v", p)
	}
}
