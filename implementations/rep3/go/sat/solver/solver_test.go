package solver

import (
	"math/rand"
	"testing"
)

func satisfies(clauses [][]int, model []bool) bool {
	for _, c := range clauses {
		ok := false
		for _, x := range c {
			v := x
			if v < 0 {
				v = -v
			}
			if model[v-1] == (x > 0) {
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

func solve(n int, clauses [][]int) (Result, []bool) {
	s := New(n)
	for _, c := range clauses {
		if !s.AddClause(c...) {
			break
		}
	}
	r := s.Solve()
	return r, s.Model()
}

func bruteForce(n int, clauses [][]int) bool {
	m := make([]bool, n)
	for mask := 0; mask < 1<<n; mask++ {
		for i := range m {
			m[i] = mask>>i&1 == 1
		}
		if satisfies(clauses, m) {
			return true
		}
	}
	return false
}

func TestTrivial(t *testing.T) {
	if r, m := solve(0, nil); r != Sat || len(m) != 0 {
		t.Fatalf("empty formula: %v %v", r, m)
	}
	if r, _ := solve(2, nil); r != Sat {
		t.Fatal("no clauses should be SAT")
	}
	if r, _ := solve(1, [][]int{{}}); r != Unsat {
		t.Fatal("empty clause should be UNSAT")
	}
	if r, _ := solve(1, [][]int{{1}, {-1}}); r != Unsat {
		t.Fatal("conflicting units should be UNSAT")
	}
}

func TestTautologyAndDuplicates(t *testing.T) {
	cl := [][]int{{1, -1}, {2, 2, -3}, {3}, {-1, -1}}
	r, m := solve(3, cl)
	if r != Sat || !satisfies(cl, m) {
		t.Fatalf("got %v %v", r, m)
	}
}

func TestUnitChain(t *testing.T) {
	cl := [][]int{{1}, {-1, 2}, {-2, 3}, {-3, 4}}
	r, m := solve(4, cl)
	if r != Sat || !m[0] || !m[1] || !m[2] || !m[3] {
		t.Fatalf("got %v %v", r, m)
	}
}

func TestPackedClausesUNSAT(t *testing.T) {
	cl := [][]int{{1, 2}, {-1, 2}, {-1, -2}, {1, -2}}
	if r, _ := solve(2, cl); r != Unsat {
		t.Fatal("expected UNSAT")
	}
}

func TestGrowsVariables(t *testing.T) {
	s := New(0)
	s.AddClause(3, -5)
	if s.NumVars() != 5 {
		t.Fatalf("NumVars = %d", s.NumVars())
	}
	if s.Solve() != Sat || !satisfies([][]int{{3, -5}}, s.Model()) {
		t.Fatal("bad model")
	}
	if v := s.NewVar(); v != 6 {
		t.Fatalf("NewVar = %d", v)
	}
}

func TestZeroLiteralPanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected panic")
		}
	}()
	New(1).AddClause(0)
}

func pigeonhole(n int) (int, [][]int) {
	// n+1 pigeons, n holes; var(p,h) = p*n+h+1.
	var cl [][]int
	for p := 0; p <= n; p++ {
		row := make([]int, n)
		for h := 0; h < n; h++ {
			row[h] = p*n + h + 1
		}
		cl = append(cl, row)
	}
	for h := 0; h < n; h++ {
		for p := 0; p <= n; p++ {
			for q := p + 1; q <= n; q++ {
				cl = append(cl, []int{-(p*n + h + 1), -(q*n + h + 1)})
			}
		}
	}
	return (n + 1) * n, cl
}

func TestPigeonhole(t *testing.T) {
	n, cl := pigeonhole(7)
	if r, _ := solve(n, cl); r != Unsat {
		t.Fatal("PHP should be UNSAT")
	}
}

func TestRandomAgainstBruteForce(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for iter := 0; iter < 500; iter++ {
		n := 3 + rng.Intn(10)
		m := rng.Intn(5*n + 1)
		var cl [][]int
		for i := 0; i < m; i++ {
			k := rng.Intn(4)
			c := make([]int, k)
			for j := range c {
				c[j] = 1 + rng.Intn(n)
				if rng.Intn(2) == 0 {
					c[j] = -c[j]
				}
			}
			cl = append(cl, c)
		}
		r, model := solve(n, cl)
		want := bruteForce(n, cl)
		if (r == Sat) != want {
			t.Fatalf("iter %d: solver=%v brute=%v clauses=%v", iter, r, want, cl)
		}
		if r == Sat && !satisfies(cl, model) {
			t.Fatalf("iter %d: model does not satisfy %v", iter, cl)
		}
	}
}

// Hard enough to trigger restarts, learnt-clause reduction and rescaling.
func TestRandom3SATStress(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	for iter := 0; iter < 6; iter++ {
		n := 150
		m := int(4.26 * float64(n))
		cl := make([][]int, m)
		for i := range cl {
			c := make([]int, 3)
			for j := range c {
				c[j] = 1 + rng.Intn(n)
				if rng.Intn(2) == 0 {
					c[j] = -c[j]
				}
			}
			cl[i] = c
		}
		s := New(n)
		for _, c := range cl {
			s.AddClause(c...)
		}
		if s.Solve() == Sat && !satisfies(cl, s.Model()) {
			t.Fatalf("iter %d: invalid model", iter)
		}
	}
}

func TestRestartsAndReduction(t *testing.T) {
	n, cl := pigeonhole(8)
	s := New(n)
	for _, c := range cl {
		s.AddClause(c...)
	}
	if s.Solve() != Unsat {
		t.Fatal("PHP(8) should be UNSAT")
	}
	st := s.Stats()
	if st.Conflicts == 0 || st.Restarts == 0 || st.Reductions == 0 {
		t.Fatalf("unexpected stats %+v", st)
	}
}

func TestLuby(t *testing.T) {
	want := []int{1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8}
	for i, w := range want {
		if g := luby(i); g != w {
			t.Errorf("luby(%d) = %d, want %d", i, g, w)
		}
	}
}

func TestHeapOrder(t *testing.T) {
	s := New(5)
	s.activity[3] = 5
	s.activity[1] = 2
	s.order.increased(3)
	s.order.increased(1)
	var got []int32
	for !s.order.empty() {
		got = append(got, s.order.pop())
	}
	if got[0] != 3 || got[1] != 1 {
		t.Fatalf("pop order %v", got)
	}
}

func TestDeterministic(t *testing.T) {
	n, cl := 60, [][]int{}
	rng := rand.New(rand.NewSource(3))
	for i := 0; i < 250; i++ {
		c := []int{1 + rng.Intn(n), 1 + rng.Intn(n), 1 + rng.Intn(n)}
		for j := range c {
			if rng.Intn(2) == 0 {
				c[j] = -c[j]
			}
		}
		cl = append(cl, c)
	}
	_, a := solve(n, cl)
	_, b := solve(n, cl)
	if len(a) != len(b) {
		t.Fatal("length differs")
	}
	for i := range a {
		if a[i] != b[i] {
			t.Fatal("not deterministic")
		}
	}
}
