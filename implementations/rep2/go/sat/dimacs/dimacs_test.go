package dimacs

import (
	"bytes"
	"reflect"
	"testing"
)

func TestParseBasic(t *testing.T) {
	f, err := Parse([]byte("c hi\np cnf 3 2\n1 -2 0\n2 3 0"))
	if err != nil {
		t.Fatal(err)
	}
	want := [][]int{{1, -2}, {2, 3}}
	if f.NumVars != 3 || !reflect.DeepEqual(f.Clauses, want) {
		t.Fatalf("got %+v", f)
	}
}

func TestParseLayout(t *testing.T) {
	in := "  c\n\n\t p \t cnf  2   4 \nc x\n1 2\ncfoo\n0 -1 2 0\n-1 -2 0 1 -2 0\n c end\n"
	f, err := Parse([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	want := [][]int{{1, 2}, {-1, 2}, {-1, -2}, {1, -2}}
	if !reflect.DeepEqual(f.Clauses, want) {
		t.Fatalf("got %v", f.Clauses)
	}
}

func TestParseEmptyClauseAndFormula(t *testing.T) {
	f, err := Parse([]byte("p cnf 0 0\n"))
	if err != nil || f.NumVars != 0 || len(f.Clauses) != 0 {
		t.Fatalf("%+v %v", f, err)
	}
	f, err = Parse([]byte("p cnf 1 2\n0\n1 0\n"))
	if err != nil || len(f.Clauses) != 2 || len(f.Clauses[0]) != 0 {
		t.Fatalf("%+v %v", f, err)
	}
}

func TestParseErrors(t *testing.T) {
	cases := map[string]error{
		"1 0\n":                  ErrNoHeader,
		"":                       ErrNoHeader,
		"p cnf 1\n":              ErrBadHeader,
		"p cnf 1 1\np cnf 1 1\n": ErrDupHeader,
		"p cnf 2 1\n1 2\n":       ErrUnterminated,
		"p cnf 2 1\n3 0\n":       ErrBadLiteral,
		"p cnf 2 1\n1 x 0\n":     ErrBadLiteral,
		"p cnf 2 1\n- 0\n":       ErrBadLiteral,
	}
	for in, want := range cases {
		if _, err := Parse([]byte(in)); err != want {
			t.Errorf("Parse(%q) error = %v, want %v", in, err, want)
		}
	}
	if _, err := Parse([]byte("p cnf 2 2\n1 0\n")); err == nil {
		t.Error("clause-count mismatch not detected")
	}
}

func TestWriteResult(t *testing.T) {
	var b bytes.Buffer
	if err := WriteResult(&b, true, []bool{true, false, true}); err != nil {
		t.Fatal(err)
	}
	if b.String() != "SAT\n1 -2 3 0\n" {
		t.Fatalf("got %q", b.String())
	}
	if got := string(AppendResult(nil, true, nil)); got != "SAT\n0\n" {
		t.Fatalf("got %q", got)
	}
	if got := string(AppendResult(nil, false, nil)); got != "UNSAT\n" {
		t.Fatalf("got %q", got)
	}
}
