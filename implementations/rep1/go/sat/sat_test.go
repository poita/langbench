package sat

import (
	"bytes"
	"math/rand"
	"strings"
	"testing"
)

func mustParse(t *testing.T, s string) *CNF {
	t.Helper()
	f, err := ParseDIMACS(strings.NewReader(s))
	if err != nil {
		t.Fatal(err)
	}
	return f
}

func TestLuby(t *testing.T) {
	want := []int{1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8}
	for i, w := range want {
		if got := luby(2, i); got != w {
			t.Errorf("luby(2,%d)=%d want %d", i, got, w)
		}
	}
}

func TestHeapOrder(t *testing.T) {
	act := []float64{3, 1, 4, 1, 5, 9, 2, 6}
	h := newVarHeap(&act, len(act))
	for v := range act {
		h.insert(int32(v))
	}
	prev := 1e9
	for len(h.items) > 0 {
		v := h.pop()
		if act[v] > prev {
			t.Fatalf("heap popped %v after %v", act[v], prev)
		}
		prev = act[v]
	}
}

func TestParse(t *testing.T) {
	f := mustParse(t, "c hi\n\n  p cnf 3 3\n1 -2\nc mid\n 0 2 3 0\t0\n")
	if f.NumVars != 3 || len(f.Clauses) != 3 {
		t.Fatalf("got %+v", f)
	}
	if len(f.Clauses[0]) != 2 || f.Clauses[0][1] != -2 || len(f.Clauses[2]) != 0 {
		t.Fatalf("bad clauses %v", f.Clauses)
	}
	for _, bad := range []string{
		"1 0\n", "p cnf 1 1\n2 0\n", "p cnf 1 1\n1\n", "p cnf 1 2\n1 0\n", "p cnf 1 0\np cnf 1 0\n", "p cnf 1 1\nx 0\n",
	} {
		if _, err := ParseDIMACS(strings.NewReader(bad)); err == nil {
			t.Errorf("expected error for %q", bad)
		}
	}
}

func solveString(t *testing.T, s string) Status {
	t.Helper()
	f := mustParse(t, s)
	st, m := Solve(f)
	if st == Satisfiable && !f.Satisfies(m) {
		t.Fatalf("model does not satisfy formula:\n%s", s)
	}
	return st
}

func TestSmall(t *testing.T) {
	cases := []struct {
		in   string
		want Status
	}{
		{"p cnf 0 0\n", Satisfiable},
		{"p cnf 3 0\n", Satisfiable},
		{"p cnf 2 1\n0\n", Unsatisfiable},
		{"p cnf 1 2\n1 0\n-1 0\n", Unsatisfiable},
		{"p cnf 2 2\n1 -1 0\n1 1 -2 0\n", Satisfiable},
		{"p cnf 2 4\n1 2 0 -1 2 0 -1 -2 0 1 -2 0\n", Unsatisfiable},
		{"p cnf 3 4\n1 0 -1 2 0 -2 3 0 -3 0\n", Unsatisfiable},
	}
	for _, c := range cases {
		if got := solveString(t, c.in); got != c.want {
			t.Errorf("%q: got %v want %v", c.in, got, c.want)
		}
	}
}

func pigeonhole(n int) *CNF {
	// n+1 pigeons, n holes; variable p*n+h+1.
	f := &CNF{NumVars: (n + 1) * n}
	for p := 0; p <= n; p++ {
		var c []int
		for h := 0; h < n; h++ {
			c = append(c, p*n+h+1)
		}
		f.Clauses = append(f.Clauses, c)
	}
	for h := 0; h < n; h++ {
		for p := 0; p <= n; p++ {
			for q := p + 1; q <= n; q++ {
				f.Clauses = append(f.Clauses, []int{-(p*n + h + 1), -(q*n + h + 1)})
			}
		}
	}
	return f
}

func TestPigeonhole(t *testing.T) {
	if st, _ := Solve(pigeonhole(7)); st != Unsatisfiable {
		t.Fatalf("PHP(7) = %v", st)
	}
}

// bruteForce decides satisfiability by enumeration.
func bruteForce(f *CNF) bool {
	m := make([]bool, f.NumVars)
	for bits := 0; bits < 1<<f.NumVars; bits++ {
		for i := range m {
			m[i] = bits>>i&1 == 1
		}
		if f.Satisfies(m) {
			return true
		}
	}
	return false
}

func TestRandomAgainstBruteForce(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for iter := 0; iter < 400; iter++ {
		nv := 1 + rng.Intn(12)
		nc := rng.Intn(5*nv + 1)
		f := &CNF{NumVars: nv}
		for i := 0; i < nc; i++ {
			k := rng.Intn(4)
			var c []int
			for j := 0; j < k; j++ {
				l := 1 + rng.Intn(nv)
				if rng.Intn(2) == 0 {
					l = -l
				}
				c = append(c, l)
			}
			f.Clauses = append(f.Clauses, c)
		}
		st, m := Solve(f)
		want := bruteForce(f)
		if (st == Satisfiable) != want {
			t.Fatalf("iter %d: got %v, brute force sat=%v: %v", iter, st, want, f.Clauses)
		}
		if st == Satisfiable && !f.Satisfies(m) {
			t.Fatalf("iter %d: bad model", iter)
		}
	}
}

func TestRandom3SATHard(t *testing.T) {
	// Exercises restarts and clause reduction at the phase transition.
	rng := rand.New(rand.NewSource(7))
	for iter := 0; iter < 5; iter++ {
		nv := 150
		f := &CNF{NumVars: nv}
		for i := 0; i < int(4.26*float64(nv)); i++ {
			var c []int
			for j := 0; j < 3; j++ {
				l := 1 + rng.Intn(nv)
				if rng.Intn(2) == 0 {
					l = -l
				}
				c = append(c, l)
			}
			f.Clauses = append(f.Clauses, c)
		}
		st, m := Solve(f)
		if st == Satisfiable && !f.Satisfies(m) {
			t.Fatal("bad model")
		}
	}
}

func TestIncremental(t *testing.T) {
	s := NewSolver(2)
	s.AddClause(1, 2)
	if s.Solve() != Satisfiable {
		t.Fatal("want SAT")
	}
	s.AddClause(-1)
	s.AddClause(-2)
	if s.Solve() != Unsatisfiable {
		t.Fatal("want UNSAT")
	}
	if s.AddClause(1) {
		t.Fatal("AddClause after UNSAT must return false")
	}
}

func TestDeterministic(t *testing.T) {
	f := pigeonhole(6)
	_, m1 := Solve(f)
	_, m2 := Solve(f)
	if len(m1) != len(m2) {
		t.Fatal("nondeterministic")
	}
	g := mustParse(t, "p cnf 4 3\n1 2 0\n-1 3 0\n-3 4 0\n")
	_, a := Solve(g)
	_, b := Solve(g)
	for i := range a {
		if a[i] != b[i] {
			t.Fatal("nondeterministic model")
		}
	}
}

func TestWriteResult(t *testing.T) {
	var b bytes.Buffer
	WriteResult(&b, Satisfiable, []bool{true, false, true})
	if b.String() != "SAT\n1 -2 3 0\n" {
		t.Errorf("got %q", b.String())
	}
	b.Reset()
	WriteResult(&b, Satisfiable, nil)
	if b.String() != "SAT\n0\n" {
		t.Errorf("got %q", b.String())
	}
	b.Reset()
	WriteResult(&b, Unsatisfiable, nil)
	if b.String() != "UNSAT\n" {
		t.Errorf("got %q", b.String())
	}
}

func TestAddClausePanicsOutOfRange(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected panic")
		}
	}()
	NewSolver(2).AddClause(3)
}

func TestReductionKeepsCorrectness(t *testing.T) {
	f := pigeonhole(7)
	s := NewSolver(f.NumVars)
	for _, c := range f.Clauses {
		s.AddClause(c...)
	}
	s.started, s.maxLearnts = true, 30 // force frequent learnt-clause reduction
	if s.Solve() != Unsatisfiable {
		t.Fatal("want UNSAT")
	}
	if s.Stats().Reductions == 0 {
		t.Fatal("reduction was never exercised")
	}
}
