package sat_test

import (
	"fmt"
	"math/rand"
	"testing"

	"example.com/sat"
)

type cnf [][]int

func build(f cnf, nvars int) *sat.Solver {
	s := sat.NewSolver()
	for i := 0; i < nvars; i++ {
		s.NewVar()
	}
	for _, c := range f {
		lits := make([]sat.Lit, len(c))
		for i, k := range c {
			lits[i] = sat.FromDIMACS(k)
		}
		s.AddClause(lits...)
	}
	return s
}

func satisfies(f cnf, model []bool) bool {
	for _, c := range f {
		ok := false
		for _, k := range c {
			if k > 0 == model[abs(k)-1] {
				ok = true
				break
			}
		}
		if !ok {
			return false
		}
	}
	return true
}

func abs(k int) int {
	if k < 0 {
		return -k
	}
	return k
}

func bruteForce(f cnf, n int) bool {
	model := make([]bool, n)
	for m := 0; m < 1<<n; m++ {
		for i := range model {
			model[i] = m>>i&1 == 1
		}
		if satisfies(f, model) {
			return true
		}
	}
	return false
}

func TestLiterals(t *testing.T) {
	for _, k := range []int{1, -1, 7, -42} {
		l := sat.FromDIMACS(k)
		if l.DIMACS() != k || l.Not().DIMACS() != -k || l.Not().Not() != l {
			t.Errorf("round trip failed for %d", k)
		}
		if l.Negated() != (k < 0) || int(l.Var()) != abs(k)-1 {
			t.Errorf("bad decomposition of %d", k)
		}
	}
	if sat.MkLit(3, true) != sat.FromDIMACS(-4) {
		t.Error("MkLit disagrees with FromDIMACS")
	}
}

func TestSmall(t *testing.T) {
	tests := []struct {
		name  string
		nvars int
		f     cnf
		want  sat.Status
	}{
		{"no clauses", 3, nil, sat.Satisfiable},
		{"no variables", 0, nil, sat.Satisfiable},
		{"empty clause", 2, cnf{{1, 2}, {}}, sat.Unsatisfiable},
		{"unit conflict", 1, cnf{{1}, {-1}}, sat.Unsatisfiable},
		{"unit chain", 3, cnf{{1}, {-1, 2}, {-2, 3}}, sat.Satisfiable},
		{"duplicates", 2, cnf{{1, 1, -2}, {2, 2}}, sat.Satisfiable},
		{"tautology", 1, cnf{{1, -1}}, sat.Satisfiable},
		{"tautology and conflict", 2, cnf{{1, -1}, {2}, {-2}}, sat.Unsatisfiable},
		{"all four clauses", 2, cnf{{1, 2}, {-1, 2}, {-1, -2}, {1, -2}}, sat.Unsatisfiable},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := build(tc.f, tc.nvars)
			got := s.Solve()
			if got != tc.want {
				t.Fatalf("Solve() = %v, want %v", got, tc.want)
			}
			if got == sat.Satisfiable {
				m := s.Model()
				if len(m) != tc.nvars || !satisfies(tc.f, m) {
					t.Fatalf("bad model %v", m)
				}
			} else if s.Model() != nil {
				t.Fatal("Model() should be nil for UNSAT")
			}
		})
	}
}

func random3SAT(rng *rand.Rand, n, m int) cnf {
	f := make(cnf, m)
	for i := range f {
		c := make([]int, 3)
		for j := range c {
			c[j] = rng.Intn(n) + 1
			if rng.Intn(2) == 0 {
				c[j] = -c[j]
			}
		}
		f[i] = c
	}
	return f
}

func TestRandomAgainstBruteForce(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	sawSat, sawUnsat := false, false
	for i := 0; i < 600; i++ {
		n := 3 + rng.Intn(10)
		f := random3SAT(rng, n, n*4+rng.Intn(n))
		s := build(f, n)
		got := s.Solve() == sat.Satisfiable
		if want := bruteForce(f, n); got != want {
			t.Fatalf("instance %d: got sat=%v, want %v: %v", i, got, want, f)
		}
		if got {
			sawSat = true
			if !satisfies(f, s.Model()) {
				t.Fatalf("instance %d: model does not satisfy formula", i)
			}
		} else {
			sawUnsat = true
		}
	}
	if !sawSat || !sawUnsat {
		t.Fatal("test did not cover both outcomes")
	}
}

func pigeonhole(n int) (cnf, int) {
	// n+1 pigeons, n holes; variable p*n+h+1: pigeon p sits in hole h.
	v := func(p, h int) int { return p*n + h + 1 }
	var f cnf
	for p := 0; p <= n; p++ {
		c := make([]int, n)
		for h := range c {
			c[h] = v(p, h)
		}
		f = append(f, c)
	}
	for h := 0; h < n; h++ {
		for p := 0; p <= n; p++ {
			for q := p + 1; q <= n; q++ {
				f = append(f, []int{-v(p, h), -v(q, h)})
			}
		}
	}
	return f, (n + 1) * n
}

func TestPigeonhole(t *testing.T) {
	for _, n := range []int{2, 5, 8} {
		t.Run(fmt.Sprint(n), func(t *testing.T) {
			f, nv := pigeonhole(n)
			if got := build(f, nv).Solve(); got != sat.Unsatisfiable {
				t.Fatalf("PHP(%d) = %v, want UNSAT", n, got)
			}
		})
	}
}

// A hard-ish random instance exercises restarts and clause deletion.
func TestPhaseTransition(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	for i := 0; i < 5; i++ {
		f := random3SAT(rng, 150, 639)
		s := build(f, 150)
		if s.Solve() == sat.Satisfiable && !satisfies(f, s.Model()) {
			t.Fatal("invalid model")
		}
	}
}

func TestIncremental(t *testing.T) {
	s := sat.NewSolver()
	a, b := s.NewVar(), s.NewVar()
	s.AddClause(sat.MkLit(a, false), sat.MkLit(b, false))
	if s.Solve() != sat.Satisfiable {
		t.Fatal("want SAT")
	}
	s.AddClause(sat.MkLit(a, true))
	if s.Solve() != sat.Satisfiable || !s.Model()[b] || s.Model()[a] {
		t.Fatalf("want a=false b=true, got %v", s.Model())
	}
	if s.AddClause(sat.MkLit(b, true)) {
		t.Fatal("AddClause should report unsatisfiable")
	}
	if s.Solve() != sat.Unsatisfiable {
		t.Fatal("want UNSAT")
	}
}

func TestAutoCreatesVariables(t *testing.T) {
	s := sat.NewSolver()
	s.AddClause(sat.FromDIMACS(5))
	if s.NumVars() != 5 || s.Solve() != sat.Satisfiable || !s.Model()[4] {
		t.Fatal("variables were not created on demand")
	}
}

func ExampleSolver() {
	s := sat.NewSolver()
	a, b := s.NewVar(), s.NewVar()
	s.AddClause(sat.MkLit(a, false), sat.MkLit(b, false)) // a or b
	s.AddClause(sat.MkLit(a, true))                       // not a
	fmt.Println(s.Solve(), s.Model())
	// Output: SAT [false true]
}
