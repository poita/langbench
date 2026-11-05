package solver

import (
	"math/rand"
	"testing"
)

// satisfies reports whether model satisfies every clause.
func satisfies(model []bool, clauses [][]int) bool {
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

func bruteForce(n int, clauses [][]int) bool {
	m := make([]bool, n)
	for mask := 0; mask < 1<<n; mask++ {
		for i := range m {
			m[i] = mask>>i&1 == 1
		}
		if satisfies(m, clauses) {
			return true
		}
	}
	return false
}

func solve(n int, clauses [][]int) (Result, []bool) {
	s := New(n)
	for _, c := range clauses {
		s.AddClause(c...)
	}
	r := s.Solve()
	if r == Sat {
		return r, s.Model()
	}
	return r, nil
}

func TestTrivial(t *testing.T) {
	if r, m := solve(0, nil); r != Sat || len(m) != 0 {
		t.Fatalf("empty formula: %v %v", r, m)
	}
	if r, m := solve(3, nil); r != Sat || len(m) != 3 {
		t.Fatalf("no clauses: %v %v", r, m)
	}
	if r, _ := solve(2, [][]int{{1, 2}, {}}); r != Unsat {
		t.Fatal("empty clause must be UNSAT")
	}
	if r, _ := solve(1, [][]int{{1}, {-1}}); r != Unsat {
		t.Fatal("unit conflict must be UNSAT")
	}
}

func TestUnitChain(t *testing.T) {
	cl := [][]int{{1}, {-1, 2}, {-2, 3}, {-3, 4}}
	r, m := solve(4, cl)
	if r != Sat || !satisfies(m, cl) {
		t.Fatalf("got %v %v", r, m)
	}
	for i, v := range m {
		if !v {
			t.Errorf("var %d should be true", i+1)
		}
	}
}

func TestDuplicatesAndTautologies(t *testing.T) {
	cl := [][]int{{1, 1, -2}, {2, -2}, {-1, -1}, {2, 3, 3}}
	r, m := solve(3, cl)
	if r != Sat || !satisfies(m, cl) {
		t.Fatalf("got %v %v", r, m)
	}
	// A tautology alone must not constrain anything and must not be stripped
	// into an empty clause.
	if r, _ := solve(1, [][]int{{1, -1}}); r != Sat {
		t.Fatal("tautology must be SAT")
	}
}

func TestPackedExample(t *testing.T) {
	cl := [][]int{{1, 2}, {-1, 2}, {-1, -2}, {1, -2}}
	if r, _ := solve(2, cl); r != Unsat {
		t.Fatal("want UNSAT")
	}
}

func TestPigeonhole(t *testing.T) {
	for n := 2; n <= 8; n++ {
		// n+1 pigeons, n holes; variable p*n+h+1 = pigeon p in hole h.
		var cl [][]int
		for p := 0; p <= n; p++ {
			c := make([]int, n)
			for h := range c {
				c[h] = p*n + h + 1
			}
			cl = append(cl, c)
		}
		for h := 0; h < n; h++ {
			for p := 0; p <= n; p++ {
				for q := p + 1; q <= n; q++ {
					cl = append(cl, []int{-(p*n + h + 1), -(q*n + h + 1)})
				}
			}
		}
		if r, _ := solve((n+1)*n, cl); r != Unsat {
			t.Errorf("PHP(%d) should be UNSAT", n)
		}
	}
}

func randomCNF(rng *rand.Rand, n, m, k int) [][]int {
	cl := make([][]int, m)
	for i := range cl {
		c := make([]int, k)
		for j := range c {
			c[j] = rng.Intn(n) + 1
			if rng.Intn(2) == 0 {
				c[j] = -c[j]
			}
		}
		cl[i] = c
	}
	return cl
}

func TestRandomAgainstBruteForce(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for iter := 0; iter < 600; iter++ {
		n := 3 + rng.Intn(10)
		m := rng.Intn(6 * n)
		cl := randomCNF(rng, n, m, 1+rng.Intn(3))
		r, model := solve(n, cl)
		want := bruteForce(n, cl)
		if (r == Sat) != want {
			t.Fatalf("iter %d: solver %v, brute force sat=%v, clauses %v", iter, r, want, cl)
		}
		if r == Sat && !satisfies(model, cl) {
			t.Fatalf("iter %d: model does not satisfy %v", iter, cl)
		}
	}
}

func TestHardRandom3SAT(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	for iter := 0; iter < 5; iter++ {
		n := 150
		cl := randomCNF(rng, n, int(4.26*float64(n)), 3)
		r, model := solve(n, cl)
		if r == Sat && !satisfies(model, cl) {
			t.Fatalf("invalid model")
		}
	}
}

func TestDeterministic(t *testing.T) {
	rng := rand.New(rand.NewSource(3))
	cl := randomCNF(rng, 100, 400, 3)
	_, a := solve(100, cl)
	_, b := solve(100, cl)
	if len(a) != len(b) {
		t.Fatal("length differs")
	}
	for i := range a {
		if a[i] != b[i] {
			t.Fatal("models differ between identical runs")
		}
	}
}

func TestIncremental(t *testing.T) {
	s := New(2)
	s.AddClause(1, 2)
	if s.Solve() != Sat {
		t.Fatal("want SAT")
	}
	s.AddClause(-1)
	if s.Solve() != Sat || !s.Value(2) || s.Value(1) {
		t.Fatalf("want 1=false 2=true, got %v", s.Model())
	}
	s.AddClause(-2)
	if s.Solve() != Unsat {
		t.Fatal("want UNSAT")
	}
	if s.AddClause(1, 2) {
		t.Fatal("AddClause must report false after UNSAT")
	}
}

func TestVariablesGrowOnDemand(t *testing.T) {
	s := New(0)
	s.AddClause(5, -3)
	if s.NumVars() != 5 {
		t.Fatalf("NumVars = %d", s.NumVars())
	}
	if s.Solve() != Sat || len(s.Model()) != 5 {
		t.Fatal("bad model")
	}
}

func TestReduceDB(t *testing.T) {
	// A tiny learnt-clause limit forces many reductions and watch rebuilds.
	rng := rand.New(rand.NewSource(11))
	for iter := 0; iter < 5; iter++ {
		n := 110
		cl := randomCNF(rng, n, int(4.3*float64(n)), 3)
		s := New(n)
		s.minLearnts = 10
		for _, c := range cl {
			s.AddClause(c...)
		}
		ref, _ := solve(n, cl)
		r := s.Solve()
		if r != ref {
			t.Fatalf("iter %d: reduced run says %v, normal run says %v", iter, r, ref)
		}
		if r == Sat && !satisfies(s.Model(), cl) {
			t.Fatal("invalid model")
		}
	}
}

func TestLuby(t *testing.T) {
	want := []int{1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8}
	for i, w := range want {
		if got := luby(i); got != w {
			t.Errorf("luby(%d) = %d, want %d", i, got, w)
		}
	}
}

func TestHeapOrder(t *testing.T) {
	act := []float64{3, 1, 4, 1, 5, 9, 2, 6}
	h := varHeap{act: &act}
	h.grow(len(act))
	for v := range act {
		h.insert(int32(v))
	}
	act[1] = 100
	h.increased(1)
	var got []int32
	for !h.empty() {
		got = append(got, h.pop())
	}
	if got[0] != 1 || got[1] != 5 {
		t.Fatalf("unexpected pop order %v", got)
	}
	for i := 1; i < len(got); i++ {
		if act[got[i-1]] < act[got[i]] {
			t.Fatalf("not descending: %v", got)
		}
	}
}
