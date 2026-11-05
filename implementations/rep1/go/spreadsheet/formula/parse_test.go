package formula

import (
	"errors"
	"testing"

	"example.com/spreadsheet/cellref"
)

func key(name string) int32 {
	k, _ := cellref.ParseKey(name)
	return int32(k)
}

func TestPrecedenceShape(t *testing.T) {
	e, err := Parse("1+2*3")
	if err != nil {
		t.Fatal(err)
	}
	root := e.Nodes[e.Root]
	if root.Kind != KindBin || BinOp(root.Op) != OpAdd {
		t.Fatalf("root should be +, got %+v", root)
	}
	if r := e.Nodes[root.B]; r.Kind != KindBin || BinOp(r.Op) != OpMul {
		t.Fatalf("right child should be *, got %+v", r)
	}
}

func TestLeftAssociative(t *testing.T) {
	e, _ := Parse("8-4-2")
	root := e.Nodes[e.Root]
	if l := e.Nodes[root.A]; l.Kind != KindBin {
		t.Fatalf("expected (8-4)-2, got %+v", root)
	}
}

func TestComparisonOperators(t *testing.T) {
	for src, want := range map[string]BinOp{"1=2": OpEq, "1<>2": OpNe, "1<2": OpLt, "1>2": OpGt, "1<=2": OpLe, "1>=2": OpGe} {
		e, err := Parse(src)
		if err != nil {
			t.Fatal(src, err)
		}
		if got := BinOp(e.Nodes[e.Root].Op); got != want {
			t.Errorf("%s: op %v want %v", src, got, want)
		}
	}
}

func TestInvalidRefs(t *testing.T) {
	for _, src := range []string{"AAA1", "A0", "A10000", "A01", "SUM(A1:AAA1)", "IF(1,2,A0)"} {
		e, err := Parse(src)
		if err != nil || !e.Invalid {
			t.Errorf("%q: want invalid expression, got %+v err=%v", src, e, err)
		}
		if deps := e.Deps(nil); len(deps) != 0 {
			t.Errorf("%q: invalid formula has deps", src)
		}
	}
	if e, _ := Parse("A1+ZZ9999"); e.Invalid {
		t.Error("valid refs flagged invalid")
	}
}

func TestSyntaxErrors(t *testing.T) {
	for _, src := range []string{"", "1+", "(1", "FOO(1)", "SUM()", "1 2", `"abc`, "IF(1,2)"} {
		_, err := Parse(src)
		var se *SyntaxError
		if !errors.As(err, &se) {
			t.Errorf("%q: want SyntaxError, got %v", src, err)
		}
	}
}

func TestRangeResolveNormalisesCorners(t *testing.T) {
	e, err := Parse("SUM(B2:A1)")
	if err != nil {
		t.Fatal(err)
	}
	var seen []int32
	e.Resolve(func(k int32) int32 { seen = append(seen, k); return k })
	want := []int32{key("A1"), key("B1"), key("A2"), key("B2")}
	if len(seen) != 4 {
		t.Fatalf("got %v", seen)
	}
	for i := range want {
		if seen[i] != want[i] {
			t.Fatalf("row-major order wrong: got %v want %v", seen, want)
		}
	}
}

func TestSpacesAndNesting(t *testing.T) {
	e, err := Parse(" IF( A1 > 2 , SUM( A1:A3 , 4 ) , \"a b\" ) & ( ( 1 ) ) ")
	if err != nil || e.Invalid {
		t.Fatalf("err=%v", err)
	}
}
