package sexpr

import "testing"

func TestRoundTrip(t *testing.T) {
	src := "(card X ; comment\n  (name \"A (b); c\") (n -12 007) (e))"
	nodes, err := ParseAll(src)
	if err != nil || len(nodes) != 1 {
		t.Fatalf("parse: %v %v", nodes, err)
	}
	want := `(card X (name "A (b); c") (n -12 7) (e))`
	if got := nodes[0].String(); got != want {
		t.Fatalf("got %s want %s", got, want)
	}
}

func TestErrors(t *testing.T) {
	for _, src := range []string{
		"(a", "a)", `(a "x`, "(a \"x\ny\")", "(a 99999999999999999999)",
	} {
		if _, err := ParseAll(src); err == nil {
			t.Errorf("expected error for %q", src)
		}
	}
}

func TestAtomKinds(t *testing.T) {
	nodes, err := ParseAll("(- -x 1a -5 plating:1 )")
	if err != nil {
		t.Fatal(err)
	}
	k := nodes[0].Kids
	kinds := []Kind{Symbol, Symbol, Symbol, Int, Symbol}
	for i := range kinds {
		if k[i].Kind != kinds[i] {
			t.Errorf("atom %d kind %v want %v", i, k[i].Kind, kinds[i])
		}
	}
}
