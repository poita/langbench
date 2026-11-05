package solver

import "testing"

func TestTableSizes(t *testing.T) {
	tb := newTables()
	want := [4]int{2048, 1082565, 29400, 1327104}
	wantMoves := [4]int{18, 14, 10, 6}
	for i, p := range tb.phases {
		if len(p.dist) != want[i] {
			t.Errorf("phase %d table has %d entries, want %d", i+1, len(p.dist), want[i])
		}
		if len(p.moves) != wantMoves[i] {
			t.Errorf("phase %d has %d moves, want %d", i+1, len(p.moves), wantMoves[i])
		}
	}
}

func TestTableReachability(t *testing.T) {
	tb := newTables()
	reach := func(i int) (n int, maxd uint8) {
		for _, d := range tb.phases[i].dist {
			if d != unvisited {
				n++
				if d > maxd {
					maxd = d
				}
			}
		}
		return
	}
	// Every coset is reachable in phases 1-3; phase 4 reaches |G3| states.
	for i, want := range []int{2048, 1082565, 29400, 663552} {
		if n, _ := reach(i); n != want {
			t.Errorf("phase %d reaches %d states, want %d", i+1, n, want)
		}
	}
	// The worst-case phase lengths bound the solution length at 45.
	for i, want := range []uint8{7, 10, 13, 15} {
		if _, d := reach(i); d > want {
			t.Errorf("phase %d depth %d exceeds %d", i+1, d, want)
		}
	}
}

func TestCornerGroups(t *testing.T) {
	tb := newTables()
	n := 0
	for _, i := range tb.halfIdx {
		if i >= 0 {
			n++
		}
	}
	if n != numCorner96 {
		t.Errorf("half-turn corner group has %d elements", n)
	}
	if tb.classOf[0] != 0 {
		t.Error("identity should be in class 0")
	}
}
