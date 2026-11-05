package orderedmap

import (
	"math"
	"math/rand"
	"sort"
	"testing"
)

// model is a trivially correct sorted-slice reference implementation.
type model struct {
	keys []int64
	vals map[int64]string
}

func newModel() *model { return &model{vals: map[int64]string{}} }

func (md *model) idx(k int64) int {
	return sort.Search(len(md.keys), func(i int) bool { return md.keys[i] >= k })
}

func (md *model) put(k int64, v string) bool {
	i := md.idx(k)
	_, had := md.vals[k]
	if !had {
		md.keys = append(md.keys, 0)
		copy(md.keys[i+1:], md.keys[i:])
		md.keys[i] = k
	}
	md.vals[k] = v
	return !had
}

func (md *model) del(k int64) bool {
	if _, had := md.vals[k]; !had {
		return false
	}
	i := md.idx(k)
	md.keys = append(md.keys[:i], md.keys[i+1:]...)
	delete(md.vals, k)
	return true
}

func TestEmpty(t *testing.T) {
	var m Map
	if m.Len() != 0 || m.Rank(5) != 0 || m.Delete(1) {
		t.Fatal("bad empty map")
	}
	if _, ok := m.Get(1); ok {
		t.Fatal("get on empty")
	}
	if _, ok := m.Min(); ok {
		t.Fatal("min on empty")
	}
	if _, ok := m.Max(); ok {
		t.Fatal("max on empty")
	}
	if _, ok := m.Floor(1); ok {
		t.Fatal("floor on empty")
	}
	if _, ok := m.Successor(1); ok {
		t.Fatal("succ on empty")
	}
	if _, ok := m.Select(0); ok {
		t.Fatal("select on empty")
	}
	m.Ascend(math.MinInt64, math.MaxInt64, func(int64, []byte) bool { t.Fatal("visited"); return true })
}

func TestPutGetReplace(t *testing.T) {
	m := New(4)
	if !m.Put(5, []byte("five")) {
		t.Fatal("first put should insert")
	}
	if m.Put(5, []byte("FIVE")) {
		t.Fatal("second put should replace")
	}
	if v, ok := m.Get(5); !ok || string(v) != "FIVE" {
		t.Fatalf("got %q %v", v, ok)
	}
	if m.Len() != 1 {
		t.Fatal("len")
	}
}

func TestExtremeKeys(t *testing.T) {
	m := New(0)
	m.Put(math.MinInt64, []byte("lo"))
	m.Put(math.MaxInt64, []byte("hi"))
	m.Put(0, []byte("z"))
	if _, ok := m.Successor(math.MaxInt64); ok {
		t.Error("succ(max)")
	}
	if _, ok := m.Predecessor(math.MinInt64); ok {
		t.Error("pred(min)")
	}
	if k, ok := m.Floor(math.MinInt64 + 1); !ok || k != math.MinInt64 {
		t.Error("floor")
	}
	if k, ok := m.Ceil(1); !ok || k != math.MaxInt64 {
		t.Error("ceil")
	}
	if r := m.Rank(math.MaxInt64); r != 2 {
		t.Errorf("rank = %d", r)
	}
	if !m.Delete(math.MinInt64) || m.Delete(math.MinInt64) {
		t.Error("delete")
	}
}

func TestSortedInsertAndDescendingDelete(t *testing.T) {
	const n = 50000
	m := New(n)
	for i := int64(0); i < n; i++ {
		m.Put(i, nil)
	}
	if err := m.Validate(); err != nil {
		t.Fatal(err)
	}
	if h := m.nodes[m.root].height; h > 22 {
		t.Fatalf("height %d too large", h)
	}
	for i := int64(n - 1); i >= 0; i-- {
		if !m.Delete(i) {
			t.Fatalf("delete %d", i)
		}
		if i%5000 == 0 {
			if err := m.Validate(); err != nil {
				t.Fatal(err)
			}
		}
	}
	if m.Len() != 0 {
		t.Fatal("not empty")
	}
}

func TestAscendEarlyStopAndBounds(t *testing.T) {
	m := New(0)
	for i := int64(0); i < 100; i += 10 {
		m.Put(i, []byte{byte(i)})
	}
	var got []int64
	m.Ascend(15, 55, func(k int64, v []byte) bool { got = append(got, k); return true })
	want := []int64{20, 30, 40, 50}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v", got)
		}
	}
	got = got[:0]
	m.Ascend(0, 90, func(k int64, _ []byte) bool { got = append(got, k); return len(got) < 3 })
	if len(got) != 3 {
		t.Fatalf("early stop: %v", got)
	}
	m.Ascend(50, 40, func(int64, []byte) bool { t.Fatal("lo>hi visited"); return true })
}

func TestRandomAgainstModel(t *testing.T) {
	for seed := int64(1); seed <= 5; seed++ {
		rng := rand.New(rand.NewSource(seed))
		m, md := New(0), newModel()
		span := int64(300)
		if seed%2 == 0 {
			span = 5000
		}
		key := func() int64 {
			k := rng.Int63n(span) - span/2
			switch rng.Intn(40) {
			case 0:
				return math.MinInt64
			case 1:
				return math.MaxInt64
			}
			return k
		}
		for step := 0; step < 20000; step++ {
			k := key()
			switch rng.Intn(10) {
			case 0, 1, 2, 3:
				v := string(rune('a' + rng.Intn(26)))
				if got, want := m.Put(k, []byte(v)), md.put(k, v); got != want {
					t.Fatalf("put %d: %v want %v", k, got, want)
				}
			case 4, 5, 6:
				if got, want := m.Delete(k), md.del(k); got != want {
					t.Fatalf("delete %d: %v want %v", k, got, want)
				}
			default:
				checkQueries(t, m, md, k, rng.Intn(len(md.keys)+3))
			}
			if step%997 == 0 {
				if err := m.Validate(); err != nil {
					t.Fatal(err)
				}
			}
		}
		if err := m.Validate(); err != nil {
			t.Fatal(err)
		}
	}
}

func checkQueries(t *testing.T, m *Map, md *model, k int64, sel int) {
	t.Helper()
	n := len(md.keys)
	if m.Len() != n {
		t.Fatalf("len %d want %d", m.Len(), n)
	}
	v, ok := m.Get(k)
	if mv, mok := md.vals[k]; ok != mok || string(v) != mv {
		t.Fatalf("get %d", k)
	}
	i := md.idx(k) // first index with key >= k
	exp := func(j int) (int64, bool) {
		if j < 0 || j >= n {
			return 0, false
		}
		return md.keys[j], true
	}
	_, present := md.vals[k]
	cmp := func(name string, gk int64, gok bool, wk int64, wok bool) {
		if gk != wk || gok != wok {
			t.Fatalf("%s(%d) = %d,%v want %d,%v", name, k, gk, gok, wk, wok)
		}
	}
	gk, gok := m.Ceil(k)
	wk, wok := exp(i)
	cmp("ceil", gk, gok, wk, wok)
	gk, gok = m.Successor(k)
	if present {
		wk, wok = exp(i + 1)
	} else {
		wk, wok = exp(i)
	}
	cmp("succ", gk, gok, wk, wok)
	gk, gok = m.Predecessor(k)
	wk, wok = exp(i - 1)
	cmp("pred", gk, gok, wk, wok)
	gk, gok = m.Floor(k)
	if present {
		wk, wok = exp(i)
	} else {
		wk, wok = exp(i - 1)
	}
	cmp("floor", gk, gok, wk, wok)
	if r := m.Rank(k); r != i {
		t.Fatalf("rank(%d) = %d want %d", k, r, i)
	}
	gk, gok = m.Select(sel)
	wk, wok = exp(sel)
	cmp("select", gk, gok, wk, wok)
	gk, gok = m.Min()
	wk, wok = exp(0)
	cmp("min", gk, gok, wk, wok)
	gk, gok = m.Max()
	wk, wok = exp(n - 1)
	cmp("max", gk, gok, wk, wok)
	// range [k, k+delta] without overflow
	hi := k + 50
	if hi < k {
		hi = math.MaxInt64
	}
	var got []int64
	m.Ascend(k, hi, func(key int64, _ []byte) bool { got = append(got, key); return true })
	var want []int64
	for _, x := range md.keys {
		if x >= k && x <= hi {
			want = append(want, x)
		}
	}
	if len(got) != len(want) {
		t.Fatalf("range(%d,%d) = %v want %v", k, hi, got, want)
	}
	for x := range got {
		if got[x] != want[x] {
			t.Fatalf("range(%d,%d) = %v want %v", k, hi, got, want)
		}
	}
}
