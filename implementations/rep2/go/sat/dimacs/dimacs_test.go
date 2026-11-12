package dimacs

import (
	"bytes"
	"reflect"
	"strings"
	"testing"

	"example.com/sat"
)

func TestParse(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want CNF
	}{
		{"empty", "p cnf 0 0", CNF{}},
		{"simple", "c hi\np cnf 3 2\n1 -2 0\n2 3 0\n", CNF{3, [][]int{{1, -2}, {2, 3}}}},
		{"split and packed", "p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0", CNF{2, [][]int{{1, 2}, {-1, 2}, {-1, -2}, {1, -2}}}},
		{"comments and blanks mid-clause", "  \tc x\n p  cnf\t2  2 \n1\ncfoo\n\n  c\n2 0\n0\n", CNF{2, [][]int{{1, 2}, {}}}},
		{"repeats and tautology", "p cnf 2 2\n1 1 -2 0\n1 -1 0\n", CNF{2, [][]int{{1, 1, -2}, {1, -1}}}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Parse(strings.NewReader(tc.in))
			if err != nil {
				t.Fatal(err)
			}
			if got.NumVars != tc.want.NumVars || len(got.Clauses) != len(tc.want.Clauses) {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
			for i := range got.Clauses {
				if !reflect.DeepEqual(append([]int{}, got.Clauses[i]...), append([]int{}, tc.want.Clauses[i]...)) {
					t.Fatalf("clause %d: got %v, want %v", i, got.Clauses[i], tc.want.Clauses[i])
				}
			}
		})
	}
}

func TestParseErrors(t *testing.T) {
	for name, in := range map[string]string{
		"no header":         "1 2 0\n",
		"unterminated":      "p cnf 2 1\n1 2\n",
		"out of range":      "p cnf 2 1\n3 0\n",
		"wrong count":       "p cnf 2 2\n1 0\n",
		"bad header":        "p dnf 2 1\n1 0\n",
		"clause pre-header": "1 0\np cnf 1 1\n",
	} {
		if _, err := Parse(strings.NewReader(in)); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

func TestWriteResult(t *testing.T) {
	var b bytes.Buffer
	WriteResult(&b, sat.Satisfiable, []bool{true, false, true})
	if b.String() != "SAT\n1 -2 3 0\n" {
		t.Errorf("got %q", b.String())
	}
	b.Reset()
	WriteResult(&b, sat.Satisfiable, nil)
	if b.String() != "SAT\n0\n" {
		t.Errorf("got %q", b.String())
	}
	b.Reset()
	WriteResult(&b, sat.Unsatisfiable, nil)
	if b.String() != "UNSAT\n" {
		t.Errorf("got %q", b.String())
	}
}

func TestSolverFromCNF(t *testing.T) {
	f, err := Parse(strings.NewReader("p cnf 4 2\n1 2 0\n-1 0\n"))
	if err != nil {
		t.Fatal(err)
	}
	s := f.Solver()
	if s.Solve() != sat.Satisfiable {
		t.Fatal("want SAT")
	}
	if m := s.Model(); len(m) != 4 || m[0] || !m[1] {
		t.Fatalf("bad model %v", m)
	}
}
