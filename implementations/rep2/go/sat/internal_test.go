package sat

import "testing"

func TestLuby(t *testing.T) {
	want := []int{1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8}
	for i, w := range want {
		if got := luby(i); got != w {
			t.Errorf("luby(%d) = %d, want %d", i, got, w)
		}
	}
}

func TestHeapOrder(t *testing.T) {
	s := NewSolver()
	for i := 0; i < 20; i++ {
		s.NewVar()
	}
	for v := range s.activity {
		s.activity[v] = float64((v * 7) % 20)
		s.order.increased(Var(v))
	}
	prev := 1e9
	for !s.order.empty() {
		v := s.order.removeMax()
		if s.activity[v] > prev {
			t.Fatal("heap out of order")
		}
		prev = s.activity[v]
	}
}

func TestReduceDBKeepsBinaries(t *testing.T) {
	s := NewSolver()
	for i := 0; i < 10; i++ {
		s.NewVar()
	}
	for i := 0; i < 8; i++ {
		n := 2 + i%2
		c := &clause{learnt: true, activity: float64(i)}
		for j := 0; j < n; j++ {
			c.lits = append(c.lits, MkLit(Var(j), false))
		}
		s.learnts = append(s.learnts, c)
		s.attach(c)
	}
	s.reduceDB()
	bin, tern := 0, 0
	for _, c := range s.learnts {
		if len(c.lits) == 2 {
			bin++
		} else {
			tern++
		}
	}
	if bin != 4 || tern != 2 {
		t.Fatalf("kept %d binary, %d longer; want 4 and 2", bin, tern)
	}
	for _, ws := range s.watches {
		for _, w := range ws {
			found := false
			for _, c := range s.learnts {
				found = found || c == w.c
			}
			if !found {
				t.Fatal("watch list references a deleted clause")
			}
		}
	}
}
