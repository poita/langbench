package dimacs

import (
	"bytes"
	"errors"
	"reflect"
	"testing"
)

func TestParseBasic(t *testing.T) {
	in := "c hello\n  p  cnf\t3 2 \n1 -2 0\nc mid\n2\n3 0\n"
	f, err := Parse([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	if f.NumVars != 3 || !reflect.DeepEqual(f.Clauses, [][]int{{1, -2}, {2, 3}}) {
		t.Fatalf("got %+v", f)
	}
}

func TestParsePackedAndEmpty(t *testing.T) {
	f, err := Parse([]byte("p cnf 2 4\n1 2\n0 -1 2 0\n0 1 1 0")) // no trailing newline
	if err != nil {
		t.Fatal(err)
	}
	want := [][]int{{1, 2}, {-1, 2}, {}, {1, 1}}
	if !reflect.DeepEqual(f.Clauses, want) {
		t.Fatalf("got %v", f.Clauses)
	}
}

func TestParseNoClauses(t *testing.T) {
	f, err := Parse([]byte("p cnf 0 0\n"))
	if err != nil || f.NumVars != 0 || len(f.Clauses) != 0 {
		t.Fatalf("got %+v %v", f, err)
	}
}

func TestParseErrors(t *testing.T) {
	bad := map[string]string{
		"no header":      "1 0\n",
		"empty":          "",
		"unterminated":   "p cnf 2 1\n1 2\n",
		"out of range":   "p cnf 2 1\n3 0\n",
		"count mismatch": "p cnf 2 2\n1 0\n",
		"bad token":      "p cnf 2 1\n1 x 0\n",
		"duplicate hdr":  "p cnf 2 0\np cnf 2 0\n",
		"malformed hdr":  "p dnf 2 0\n",
		"clause pre-hdr": "1 0\np cnf 1 1\n",
		"lone minus":     "p cnf 2 1\n- 0\n",
	}
	for name, in := range bad {
		if _, err := Parse([]byte(in)); !errors.Is(err, ErrSyntax) {
			t.Errorf("%s: err = %v", name, err)
		}
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
	b.Reset()
	WriteResult(&b, true, nil)
	if b.String() != "SAT\n0\n" {
		t.Fatalf("got %q", b.String())
	}
	b.Reset()
	WriteResult(&b, false, nil)
	if b.String() != "UNSAT\n" {
		t.Fatalf("got %q", b.String())
	}
}
