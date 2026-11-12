package syntax

import (
	"reflect"
	"testing"
)

func TestParsePrecedence(t *testing.T) {
	lit := func(f float64) Node { return &Literal{f} }
	cases := []struct {
		src  string
		want Node
	}{
		{`1 + 2 * 3`, &Binary{"+", lit(1), &Binary{"*", lit(2), lit(3)}}},
		{`1 - 2 - 3`, &Binary{"-", &Binary{"-", lit(1), lit(2)}, lit(3)}},
		{`1, 2 | 3`, &Pipe{&Comma{lit(1), lit(2)}, lit(3)}},
		{`1 | 2, 3`, &Pipe{lit(1), &Comma{lit(2), lit(3)}}},
		{`1 or 2 and 3`, &Or{lit(1), &And{lit(2), lit(3)}}},
		{`1 - -1`, &Binary{"-", lit(1), &Neg{lit(1)}}},
		{`1 -1`, &Binary{"-", lit(1), lit(1)}},
		{`1 < 2`, &Binary{"<", lit(1), lit(2)}},
	}
	for _, c := range cases {
		got, err := Parse(c.src)
		if err != nil {
			t.Errorf("Parse(%q): %v", c.src, err)
			continue
		}
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("Parse(%q) = %#v, want %#v", c.src, got, c.want)
		}
	}
}

func TestOptionalBinding(t *testing.T) {
	n, err := Parse(`.a?`)
	if err != nil {
		t.Fatal(err)
	}
	if ix, ok := n.(*Index); !ok || !ix.Opt {
		t.Errorf(".a? parsed as %#v, want an optional Index", n)
	}
	n, _ = Parse(`(.a.b)?`)
	if _, ok := n.(*Try); !ok {
		t.Errorf("(.a.b)? parsed as %#v, want Try", n)
	}
	n, _ = Parse(`.a??`)
	if try, ok := n.(*Try); !ok {
		t.Errorf(".a?? parsed as %#v, want Try", n)
	} else if ix, ok := try.Body.(*Index); !ok || !ix.Opt {
		t.Errorf(".a?? body is %#v", try.Body)
	}
}

func TestBindingExtendsRight(t *testing.T) {
	n, err := Parse(`.a as $x | $x, 1`)
	if err != nil {
		t.Fatal(err)
	}
	as, ok := n.(*As)
	if !ok {
		t.Fatalf("got %#v", n)
	}
	if _, ok := as.Body.(*Comma); !ok {
		t.Errorf("body = %#v, want Comma", as.Body)
	}
}

func TestParseValidFilters(t *testing.T) {
	for _, src := range []string{
		`.`, `.a.b."c d"`, `.[0]`, `.[]`, `.[1:]`, `.[:2]`, `.[-1:]`, `."a"?`,
		`[.[] | select(.a > 1)]`, `{a, "b", $x, (.k): 1, c: .d | .e}`,
		`if . then 1 elif 2 then 3 else 4 end`, `if . then 1 end`,
		`reduce .[] as $x (0; . + $x)`, `. as $x | $x`, `{"a":1} * {}`,
		`"é😀"`, `sort_by(.a, -.b)`, `.a[1:2][0]`, `empty`,
	} {
		if _, err := Parse(src); err != nil {
			t.Errorf("Parse(%q): %v", src, err)
		}
	}
}

func TestParseErrors(t *testing.T) {
	for _, src := range []string{``, `.[`, `1 +`, `{a:}`, `if 1 then 2`, `"abc`, `$`, `(1`, `1 2`, `@`, `reduce . as x (0;0)`} {
		if _, err := Parse(src); err == nil {
			t.Errorf("Parse(%q) succeeded, want error", src)
		}
	}
}

func TestStringLiteralDecoding(t *testing.T) {
	n, err := Parse(`"aé😀\n"`)
	if err != nil {
		t.Fatal(err)
	}
	if got := n.(*Literal).Value; got != "aé😀\n" {
		t.Errorf("got %q", got)
	}
}
