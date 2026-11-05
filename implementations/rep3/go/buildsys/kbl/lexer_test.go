package kbl

import (
	"reflect"
	"testing"
)

func texts(toks []token) []string {
	var out []string
	for _, t := range toks {
		out = append(out, t.text)
	}
	return out
}

func TestLexLogicalLines(t *testing.T) {
	src := "let a = f(1,\n  2) # trailing\n\n# comment\nlet b = \"x # y\"   \n"
	lines, err := lexFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 2 || lines[0].no != 1 || lines[1].no != 5 {
		t.Fatalf("lines: %+v", lines)
	}
	want := []string{"let", "a", "=", "f", "(", "1", ",", "2", ")"}
	if got := texts(lines[0].toks); !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
	if got := texts(lines[1].toks); got[len(got)-1] != `"x # y"` {
		t.Errorf("got %v", got)
	}
}

func TestLexOperatorsLongestFirst(t *testing.T) {
	lines, err := lexFile("a |> b || c && d == e != f <= g >= h ++ i < j > k ~ l\n")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"a", "|>", "b", "||", "c", "&&", "d", "==", "e", "!=", "f", "<=", "g", ">=", "h", "++", "i", "<", "j", ">", "k", "~", "l"}
	if got := texts(lines[0].toks); !reflect.DeepEqual(got, want) {
		t.Errorf("got %v", got)
	}
}

func TestLexStringsWithNestedLiterals(t *testing.T) {
	src := `cmd write("{join(xs, ", ")}\n") # c` + "\n"
	lines, err := lexFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if n := len(lines[0].toks); n != 5 {
		t.Errorf("want 5 tokens, got %v", texts(lines[0].toks))
	}
}

func TestLexErrors(t *testing.T) {
	cases := map[string]int{
		"let a = \"abc\n":               1,
		"ok\nlet a = 'abc\n":            2,
		"x = (\n  1,\n":                 1,
		"a)\n":                          1,
		"a = [\n]\n)\n":                 3,
		"let a = \"{1\n":                1,
		"let a = \"{ \"x }\"\n":         1,
		"\n\n  let a = 1 $ 2\n":         3,
		"a = f(\n  \"unterminated\n)\n": 1,
	}
	for src, line := range cases {
		_, err := lexFile(src)
		se, ok := err.(*SyntaxError)
		if !ok || se.Line != line {
			t.Errorf("%q: got %v, want line %d", src, err, line)
		}
	}
}

func TestSkipLiteral(t *testing.T) {
	cases := []struct {
		s   string
		end int
		ok  bool
	}{
		{`"abc" rest`, 5, true},
		{`'it''s' x`, 7, true},
		{`"a\"b"`, 6, true},
		{`"{{}}"`, 6, true},
		{`"a}b"`, 5, true},
		{`"{f("}")}" x`, 10, true},
		{`"{'}'}"`, 7, true},
		{`"abc`, 0, false},
		{`"abc\`, 0, false},
		{`'abc`, 0, false},
		{`"{abc"`, 0, false},
	}
	for _, c := range cases {
		end, ok := skipLiteral(c.s, 0)
		if ok != c.ok || (ok && end != c.end) {
			t.Errorf("skipLiteral(%q) = %d,%v want %d,%v", c.s, end, ok, c.end, c.ok)
		}
	}
}
