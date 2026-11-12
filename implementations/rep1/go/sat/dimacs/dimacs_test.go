package dimacs

import (
	"bytes"
	"reflect"
	"strings"
	"testing"

	"example.com/sat"
)

func TestParse(t *testing.T) {
	in := "c hello\n\n  p  cnf\t4  3 \ncfoo\n1 -2\n c mid\n0 3 0 4\n\t-4 0\nc end"
	f, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	want := [][]int{{1, -2}, {3}, {4, -4}}
	if f.NumVars != 4 || !reflect.DeepEqual(f.Clauses, want) {
		t.Fatalf("got %+v, want clauses %v", f, want)
	}
}

func TestParseCounts(t *testing.T) {
	f, err := Parse(strings.NewReader("p cnf 4 4\n1 -2\n0 3 0 4\n-4 0\n0"))
	if err != nil {
		t.Fatal(err)
	}
	want := [][]int{{1, -2}, {3}, {4, -4}, nil}
	if !reflect.DeepEqual(f.Clauses, want) {
		t.Fatalf("got %v, want %v", f.Clauses, want)
	}
}

func TestParseErrors(t *testing.T) {
	for name, in := range map[string]string{
		"no header":       "1 0\n",
		"out of range":    "p cnf 1 1\n2 0\n",
		"unterminated":    "p cnf 2 1\n1 2\n",
		"wrong count":     "p cnf 2 2\n1 0\n",
		"bad token":       "p cnf 2 1\n1 x 0\n",
		"duplicate hdr":   "p cnf 2 0\np cnf 2 0\n",
		"malformed hdr":   "p cnf 2\n",
		"data before hdr": "1 0\np cnf 1 1\n",
	} {
		if _, err := Parse(strings.NewReader(in)); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
}

func TestRoundTrip(t *testing.T) {
	f := &Formula{NumVars: 3, Clauses: [][]int{{1, -2}, {3}, {}}}
	var b bytes.Buffer
	if err := f.Write(&b); err != nil {
		t.Fatal(err)
	}
	g, err := Parse(&b)
	if err != nil {
		t.Fatal(err)
	}
	if g.NumVars != 3 || len(g.Clauses) != 3 || !reflect.DeepEqual(g.Clauses[:2], f.Clauses[:2]) {
		t.Fatalf("round trip gave %+v", g)
	}
}

func TestSolveAndSatisfies(t *testing.T) {
	f, _ := Parse(strings.NewReader("p cnf 3 2\n1 -2 0\n2 3 0\n"))
	s := f.Solver()
	if s.Solve() != sat.Satisfiable || !f.Satisfies(s.Model()) {
		t.Fatal("expected a satisfying model")
	}
	if f.Satisfies([]bool{false, true, false}) {
		t.Fatal("Satisfies accepted a falsifying assignment")
	}
}

func TestWriteResult(t *testing.T) {
	var b bytes.Buffer
	WriteResult(&b, sat.Satisfiable, []bool{true, false, true})
	if b.String() != "SAT\n1 -2 3 0\n" {
		t.Fatalf("got %q", b.String())
	}
	b.Reset()
	WriteResult(&b, sat.Satisfiable, nil)
	if b.String() != "SAT\n0\n" {
		t.Fatalf("got %q", b.String())
	}
	b.Reset()
	WriteResult(&b, sat.Unsatisfiable, nil)
	if b.String() != "UNSAT\n" {
		t.Fatalf("got %q", b.String())
	}
}
