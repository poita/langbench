package syntax_test

import (
	"testing"

	"github.com/peter/jq/syntax"
)

func TestParseValid(t *testing.T) {
	for _, src := range []string{
		`.`, `.a.b.c`, `."a b"`, `.[0]`, `.[-1]`, `.[]`, `.[1:]`, `.[:2]`, `.[1:2]`,
		`.a?`, `.[]?`, `(.a.b)?`, `.a | .b, .c`, `1, 2 | f`, `1 -1`, `2 * -3`, `1 - -1`,
		`-(.a + 1)`, `[]`, `[.[] | .a]`, `{}`, `{a, "b", $x, (.k): 1, c: .d | .e}`,
		`if . then 1 elif 2 then 3 else 4 end`, `if . then 1 end`,
		`reduce .[] as $x (0; . + $x)`, `.[] as $x | $x + 1`,
		`map(select(.a > 1 and .b != null or not))`, `{"a":1}.a`, `"x" * 3`,
		`.a as $x | .b as $y | [$x, $y]`, `. as $o | .[] | $o`,
	} {
		if _, err := syntax.Parse(src); err != nil {
			t.Errorf("Parse(%q): %v", src, err)
		}
	}
}

func TestParseInvalid(t *testing.T) {
	for _, src := range []string{
		``, `.[`, `(1`, `1 +`, `{a:}`, `if 1 then 2`, `reduce . as $x (1)`, `1 2`,
		`"abc`, `@`, `.a as x | 1`, `.[1:2:3]`, `then`,
	} {
		if _, err := syntax.Parse(src); err == nil {
			t.Errorf("Parse(%q) succeeded, want error", src)
		}
	}
}

func TestPrecedenceShape(t *testing.T) {
	n, err := syntax.Parse(`a | b, c`)
	if err != nil {
		t.Fatal(err)
	}
	if n.Op != syntax.OpPipe || n.B.Op != syntax.OpComma {
		t.Errorf("a | b, c should be a | (b, c); got op %d with rhs op %d", n.Op, n.B.Op)
	}
	n, _ = syntax.Parse(`1, 2 | f`)
	if n.Op != syntax.OpPipe || n.A.Op != syntax.OpComma {
		t.Error("1, 2 | f should be (1, 2) | f")
	}
	n, _ = syntax.Parse(`1 + 2 * 3`)
	if n.Op != syntax.OpBinary || n.Bin != syntax.Add || n.B.Bin != syntax.Mul {
		t.Error("* should bind tighter than +")
	}
}

func TestOptionalMeanings(t *testing.T) {
	n, _ := syntax.Parse(`.a?`)
	if n.Op != syntax.OpIndex || !n.Optional {
		t.Error(".a? should be a tolerant index")
	}
	n, _ = syntax.Parse(`.a.b?`)
	if n.Op != syntax.OpIndex || !n.Optional || n.A.Optional {
		t.Error("only the last index of .a.b? is tolerant")
	}
	n, _ = syntax.Parse(`(1,2)?`)
	if n.Op != syntax.OpTry {
		t.Error("(1,2)? should be try")
	}
	n, _ = syntax.Parse(`.a??`)
	if n.Op != syntax.OpTry {
		t.Error("a second ? wraps in try")
	}
}

func TestErrorHasPosition(t *testing.T) {
	_, err := syntax.Parse(`1 + `)
	se, ok := err.(*syntax.Error)
	if !ok || se.Pos != 4 {
		t.Errorf("got %#v", err)
	}
}
