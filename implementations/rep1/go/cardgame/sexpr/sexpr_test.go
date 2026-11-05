package sexpr

import "testing"

func TestParseAndPrint(t *testing.T) {
	src := "(card X\t(name \"A (b); c\") ; comment\n  (cost -12)\n(n 007))"
	nodes, err := Parse([]byte(src))
	if err != nil || len(nodes) != 1 {
		t.Fatalf("parse: %v %v", nodes, err)
	}
	want := `(card X (name "A (b); c") (cost -12) (n 7))`
	if got := nodes[0].String(); got != want {
		t.Fatalf("got %s want %s", got, want)
	}
}

func TestErrors(t *testing.T) {
	cases := map[string]error{
		"(a":                       ErrUnbalanced,
		"a)":                       ErrUnbalanced,
		")":                        ErrUnbalanced,
		"(a \"b)":                  ErrUnterminated,
		"(a \"b\nc\")":             ErrUnterminated,
		"(a 99999999999999999999)": ErrBadInteger,
	}
	for src, want := range cases {
		if _, err := Parse([]byte(src)); err != want {
			t.Errorf("%q: got %v want %v", src, err, want)
		}
	}
}

func TestAtoms(t *testing.T) {
	nodes, err := Parse([]byte("a-b 12 -3 +4 5x \"\" ()"))
	if err != nil {
		t.Fatal(err)
	}
	kinds := []Kind{Symbol, Int, Int, Symbol, Symbol, String, List}
	for i, k := range kinds {
		if nodes[i].Kind != k {
			t.Errorf("node %d: kind %d want %d", i, nodes[i].Kind, k)
		}
	}
}
