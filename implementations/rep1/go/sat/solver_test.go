package sat_test

import (
	"fmt"
	"math/rand"
	"testing"

	"example.com/sat"
)

func satisfies(clauses [][]int, model []bool) bool {
	for _, c := range clauses {
		ok := false
		for _, l := range c {
			if l > 0 && model[l-1] || l < 0 && !model[-l-1] {
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

func solve(n int, clauses [][]int) (sat.Result, []bool) {
	s := sat.New()
	s.Reserve(n)
	for _, c := range clauses {
		s.AddClause(c...)
	}
	r := s.Solve()
	return r, s.Model()
}

func bruteForce(n int, clauses [][]int) bool {
	model := make([]bool, n)
	for m := 0; m < 1<<n; m++ {
		for i := range model {
			model[i] = m>>i&1 == 1
		}
		if satisfies(clauses, model) {
			return true
		}
	}
	return false
}

func TestSmall(t *testing.T) {
	tests := []struct {
		name    string
		n       int
		clauses [][]int
		want    sat.Result
	}{
		{"no clauses", 0, nil, sat.Satisfiable},
		{"unused variables", 3, nil, sat.Satisfiable},
		{"empty clause", 2, [][]int{{1, 2}, {}}, sat.Unsatisfiable},
		{"unit conflict", 1, [][]int{{1}, {-1}}, sat.Unsatisfiable},
		{"tautology", 1, [][]int{{1, -1}}, sat.Satisfiable},
		{"duplicates", 2, [][]int{{1, 1, -2}, {2, 2}}, sat.Satisfiable},
		{"all four binary", 2, [][]int{{1, 2}, {-1, 2}, {1, -2}, {-1, -2}}, sat.Unsatisfiable},
		{"implication chain", 4, [][]int{{1}, {-1, 2}, {-2, 3}, {-3, 4}}, sat.Satisfiable},
		{"long clause", 1000, [][]int{func() []int {
			c := make([]int, 1000)
			for i := range c {
				c[i] = -(i + 1)
			}
			return c
		}()}, sat.Satisfiable},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, model := solve(tc.n, tc.clauses)
			if got != tc.want {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
			if got == sat.Satisfiable {
				if len(model) != tc.n {
					t.Fatalf("model has %d values, want %d", len(model), tc.n)
				}
				if !satisfies(tc.clauses, model) {
					t.Fatalf("model %v does not satisfy the formula", model)
				}
			}
		})
	}
}

func randomKSAT(rng *rand.Rand, n, m, k int) [][]int {
	clauses := make([][]int, m)
	for i := range clauses {
		for j := 0; j < k; j++ {
			l := rng.Intn(n) + 1
			if rng.Intn(2) == 0 {
				l = -l
			}
			clauses[i] = append(clauses[i], l)
		}
	}
	return clauses
}

// Cross-check against exhaustive search on many small random formulas, with
// repeated and complementary literals allowed.
func TestRandomAgainstBruteForce(t *testing.T) {
	rng := rand.New(rand.NewSource(42))
	for i := 0; i < 600; i++ {
		n := 1 + rng.Intn(12)
		m := 1 + rng.Intn(6*n)
		k := 1 + rng.Intn(4)
		clauses := randomKSAT(rng, n, m, k)
		got, model := solve(n, clauses)
		want := bruteForce(n, clauses)
		if (got == sat.Satisfiable) != want {
			t.Fatalf("formula %v: solver says %v, brute force says sat=%v", clauses, got, want)
		}
		if want && !satisfies(clauses, model) {
			t.Fatalf("formula %v: bad model %v", clauses, model)
		}
	}
}

// Random 3-SAT at the phase transition exercises learning, restarts and
// clause deletion.
func TestPhaseTransition(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	nsat, nunsat := 0, 0
	for i := 0; i < 20; i++ {
		clauses := randomKSAT(rng, 150, 639, 3)
		got, model := solve(150, clauses)
		if got == sat.Satisfiable {
			nsat++
			if !satisfies(clauses, model) {
				t.Fatalf("instance %d: bad model", i)
			}
		} else {
			nunsat++
		}
	}
	if nsat == 0 || nunsat == 0 {
		t.Logf("sat=%d unsat=%d", nsat, nunsat)
	}
}

func pigeonhole(holes int) (int, [][]int) {
	pigeons := holes + 1
	v := func(p, h int) int { return p*holes + h + 1 }
	var cl [][]int
	for p := 0; p < pigeons; p++ {
		var c []int
		for h := 0; h < holes; h++ {
			c = append(c, v(p, h))
		}
		cl = append(cl, c)
	}
	for h := 0; h < holes; h++ {
		for p := 0; p < pigeons; p++ {
			for q := p + 1; q < pigeons; q++ {
				cl = append(cl, []int{-v(p, h), -v(q, h)})
			}
		}
	}
	return pigeons * holes, cl
}

func TestPigeonhole(t *testing.T) {
	for holes := 2; holes <= 8; holes++ {
		t.Run(fmt.Sprintf("PHP%d", holes), func(t *testing.T) {
			n, cl := pigeonhole(holes)
			if got, _ := solve(n, cl); got != sat.Unsatisfiable {
				t.Fatalf("got %v, want UNSAT", got)
			}
		})
	}
}

func TestStatsAndClauseReduction(t *testing.T) {
	// A hard-enough UNSAT instance to force restarts; also checks Stats.
	n, cl := pigeonhole(8)
	s := sat.New()
	s.Reserve(n)
	for _, c := range cl {
		s.AddClause(c...)
	}
	if s.Solve() != sat.Unsatisfiable {
		t.Fatal("want UNSAT")
	}
	st := s.Stats()
	if st.Conflicts == 0 || st.Decisions == 0 || st.Propagations == 0 {
		t.Fatalf("implausible stats %+v", st)
	}
	if s.Model() != nil {
		t.Fatal("Model should be nil after UNSAT")
	}
}

func TestResolveAfterUnsat(t *testing.T) {
	s := sat.New()
	s.AddClause(1)
	if s.AddClause(-1) {
		t.Fatal("AddClause should report unsatisfiable")
	}
	if s.Solve() != sat.Unsatisfiable || s.AddClause(2) {
		t.Fatal("solver should stay unsatisfiable")
	}
}

func TestResultString(t *testing.T) {
	if sat.Satisfiable.String() != "SAT" || sat.Unsatisfiable.String() != "UNSAT" {
		t.Fatal("bad Result strings")
	}
}

func ExampleSolver() {
	s := sat.New()
	s.AddClause(1, -2)
	s.AddClause(2, 3)
	s.AddClause(-1, -3)
	if s.Solve() == sat.Satisfiable {
		fmt.Println("satisfiable")
	}
	// Output: satisfiable
}
