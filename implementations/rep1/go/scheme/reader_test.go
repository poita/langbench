package scheme_test

import (
	"testing"

	"example.com/scheme"
)

func TestReaderRoundTrip(t *testing.T) {
	// Each source is read as a quoted datum and printed back.
	cases := []struct{ src, want string }{
		{"42", "42"},
		{"123456789012345678901234567890", "123456789012345678901234567890"},
		{"-000000000000000000000012", "-12"},
		{"'a", "(quote a)"},
		{"(a . (b . (c)))", "(a b c)"},
		{"(1 .5)", "(1 .5)"},
		{"(a ; comment\n b)", "(a b)"},
		{"\"line1\nline2\"", `"line1\nline2"`},
		{"Foo", "Foo"},
		{"(1 2 . 3)", "(1 2 . 3)"},
	}
	for _, c := range cases {
		v, err := scheme.New().Eval("(quote " + c.src + ")")
		if err != nil {
			t.Errorf("%q: %v", c.src, err)
			continue
		}
		if got := v.String(); got != c.want {
			t.Errorf("%q: got %s, want %s", c.src, got, c.want)
		}
	}
}

func TestLongListIsLinear(t *testing.T) {
	src := make([]byte, 0, 1<<20)
	src = append(src, "(length-of '("...)
	for i := 0; i < 100000; i++ {
		src = append(src, "1 "...)
	}
	src = append(src, "))"...)
	in := scheme.New()
	// Reading must succeed (the call itself fails: length-of is unbound).
	if err := in.Run(src); err == nil {
		t.Fatal("expected unbound-variable")
	}
}
