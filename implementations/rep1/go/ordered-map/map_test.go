package orderedmap

import (
	"fmt"
	"math"
	"math/rand"
	"sort"
	"testing"
)

// checkInvariants verifies BST order, AVL balance and cached sizes/heights.
func checkInvariants(t *testing.T, m *Map) {
	t.Helper()
	var check func(n *node, lo, hi *int64) (h, s int32)
	check = func(n *node, lo, hi *int64) (int32, int32) {
		if n == nil {
			return 0, 0
		}
		if lo != nil && n.key <= *lo || hi != nil && n.key >= *hi {
			t.Fatalf("BST order violated at key %d", n.key)
		}
		hl, sl := check(n.left, lo, &n.key)
		hr, sr := check(n.right, &n.key, hi)
		if d := hl - hr; d > 1 || d < -1 {
			t.Fatalf("unbalanced at key %d: %d vs %d", n.key, hl, hr)
		}
		h := max(hl, hr) + 1
		if n.height != h || n.size != sl+sr+1 {
			t.Fatalf("stale cache at key %d", n.key)
		}
		return h, n.size
	}
	check(m.root, nil, nil)
}

func TestBasic(t *testing.T) {
	m := New()
	if m.Len() != 0 {
		t.Fatal("new map not empty")
	}
	if _, ok := m.Min(); ok {
		t.Fatal("Min on empty map")
	}
	if m.Put(5, "five") {
		t.Fatal("first Put reported replace")
	}
	if !m.Put(5, "FIVE") {
		t.Fatal("second Put did not report replace")
	}
	if v, ok := m.Get(5); !ok || v != "FIVE" {
		t.Fatalf("Get(5) = %q, %v", v, ok)
	}
	if m.Delete(6) || !m.Delete(5) || m.Delete(5) {
		t.Fatal("Delete results wrong")
	}
	if m.Len() != 0 {
		t.Fatal("expected empty")
	}
}

func TestExtremes(t *testing.T) {
	m := New()
	m.Put(math.MinInt64, "lo")
	m.Put(math.MaxInt64, "hi")
	m.Put(0, "zero")
	if _, ok := m.Successor(math.MaxInt64); ok {
		t.Error("Successor(MaxInt64) should not exist")
	}
	if _, ok := m.Predecessor(math.MinInt64); ok {
		t.Error("Predecessor(MinInt64) should not exist")
	}
	if k, _ := m.Successor(math.MinInt64); k != 0 {
		t.Errorf("Successor(MinInt64) = %d", k)
	}
	if k, _ := m.Predecessor(math.MaxInt64); k != 0 {
		t.Errorf("Predecessor(MaxInt64) = %d", k)
	}
	var got []int64
	m.Ascend(func(k int64, _ string) bool { got = append(got, k); return true })
	if len(got) != 3 || got[0] != math.MinInt64 || got[2] != math.MaxInt64 {
		t.Errorf("Ascend = %v", got)
	}
}

func TestRangeEarlyStopAndEmpty(t *testing.T) {
	m := New()
	for i := int64(0); i < 10; i++ {
		m.Put(i, "v")
	}
	n := 0
	m.Range(0, 9, func(int64, string) bool { n++; return n < 3 })
	if n != 3 {
		t.Errorf("early stop visited %d", n)
	}
	m.Range(5, 4, func(int64, string) bool { t.Error("lo > hi visited"); return true })
}

// TestAgainstReference compares every operation with a sorted-slice model
// under random workloads, checking tree invariants along the way.
func TestAgainstReference(t *testing.T) {
	for _, keyRange := range []int64{20, 500, 1 << 40} {
		rng := rand.New(rand.NewSource(keyRange))
		m := New()
		model := map[int64]string{}
		sorted := func() []int64 {
			ks := make([]int64, 0, len(model))
			for k := range model {
				ks = append(ks, k)
			}
			sort.Slice(ks, func(i, j int) bool { return ks[i] < ks[j] })
			return ks
		}
		for step := 0; step < 4000; step++ {
			k := rng.Int63n(keyRange) - keyRange/2
			switch rng.Intn(3) {
			case 0:
				_, had := model[k]
				model[k] = "v"
				if m.Put(k, "v") != had {
					t.Fatalf("Put(%d) replaced mismatch", k)
				}
			case 1:
				_, had := model[k]
				delete(model, k)
				if m.Delete(k) != had {
					t.Fatalf("Delete(%d) mismatch", k)
				}
			default:
				// no mutation
			}
			if step%50 != 0 {
				continue
			}
			checkInvariants(t, m)
			ks := sorted()
			if m.Len() != len(ks) {
				t.Fatalf("Len %d != %d", m.Len(), len(ks))
			}
			q := rng.Int63n(keyRange) - keyRange/2
			i := sort.Search(len(ks), func(i int) bool { return ks[i] >= q }) // first >= q
			j := sort.Search(len(ks), func(i int) bool { return ks[i] > q })  // first > q
			if r := m.Rank(q); r != i {
				t.Fatalf("Rank(%d) = %d want %d", q, r, i)
			}
			expect := func(name string, got int64, ok bool, idx int) {
				if idx < 0 || idx >= len(ks) {
					if ok {
						t.Fatalf("%s(%d) = %d, want none", name, q, got)
					}
					return
				}
				if !ok || got != ks[idx] {
					t.Fatalf("%s(%d) = %d,%v want %d", name, q, got, ok, ks[idx])
				}
			}
			g, ok := m.Ceil(q)
			expect("Ceil", g, ok, i)
			g, ok = m.Successor(q)
			expect("Successor", g, ok, j)
			g, ok = m.Floor(q)
			expect("Floor", g, ok, j-1)
			g, ok = m.Predecessor(q)
			expect("Predecessor", g, ok, i-1)
			for idx := range ks {
				g, ok = m.Select(idx)
				expect("Select", g, ok, idx)
			}
			if _, ok := m.Select(len(ks)); ok {
				t.Fatal("Select(len) should fail")
			}
			hi := q + rng.Int63n(keyRange)
			var got []int64
			m.Range(q, hi, func(k int64, _ string) bool { got = append(got, k); return true })
			var want []int64
			for _, k := range ks {
				if k >= q && k <= hi {
					want = append(want, k)
				}
			}
			if len(got) != len(want) {
				t.Fatalf("Range(%d,%d) = %v want %v", q, hi, got, want)
			}
			for x := range got {
				if got[x] != want[x] {
					t.Fatalf("Range(%d,%d) = %v want %v", q, hi, got, want)
				}
			}
		}
	}
}

// TestAdversarialHeight checks that sorted insertion and descending
// deletion keep the tree logarithmic.
func TestAdversarialHeight(t *testing.T) {
	const n = 100000
	m := New()
	for i := int64(0); i < n; i++ {
		m.Put(i, "x")
	}
	if h := height(m.root); h > 20 {
		t.Fatalf("height %d too large for %d sorted inserts", h, n)
	}
	for i := int64(n - 1); i >= n/2; i-- {
		if !m.Delete(i) {
			t.Fatalf("Delete(%d) failed", i)
		}
	}
	checkInvariants(t, m)
	if m.Len() != n/2 {
		t.Fatalf("Len = %d", m.Len())
	}
}

func BenchmarkPut(b *testing.B) {
	m := New()
	for i := 0; i < b.N; i++ {
		m.Put(int64(i), "v")
	}
}

func ExampleMap_Rank() {
	m := New()
	m.Put(10, "a")
	m.Put(20, "b")
	m.Put(30, "c")
	k, _ := m.Floor(25)
	r := m.Rank(21)
	s, _ := m.Select(2)
	fmt.Println(k, r, s)
	// Output: 20 2 30
}
