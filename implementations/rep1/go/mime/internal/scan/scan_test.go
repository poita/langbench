package scan

import "testing"

func TestQuoted(t *testing.T) {
	cases := []struct {
		in   string
		text string
		next int
	}{
		{`"abc" rest`, "abc", 5},
		{`"a\"b"`, `a"b`, 6},
		{`"a\\"`, `a\`, 5},
		{`"open`, "open", 5},
		{`"end\`, `end\`, 5},
		{`""`, "", 2},
	}
	for _, c := range cases {
		text, next := Quoted(c.in, 0)
		if text != c.text || next != c.next {
			t.Errorf("Quoted(%q) = %q, %d; want %q, %d", c.in, text, next, c.text, c.next)
		}
	}
}

func TestCommentAndLiteral(t *testing.T) {
	if got := Comment("(a (b) \\) c) x", 0); got != 12 {
		t.Errorf("Comment = %d, want 12", got)
	}
	if got := Comment("(open", 0); got != 5 {
		t.Errorf("unterminated Comment = %d", got)
	}
	if got := Literal(`[1.2\]3] x`, 0); got != 8 {
		t.Errorf("Literal = %d, want 8", got)
	}
}

func TestHelpers(t *testing.T) {
	if Trim(" \t x y\t ") != "x y" {
		t.Error("Trim")
	}
	if LowerASCII("AbCÉ") != "abcÉ" {
		t.Error("LowerASCII")
	}
	if HexVal('f') != 15 || HexVal('G') != -1 {
		t.Error("HexVal")
	}
}
