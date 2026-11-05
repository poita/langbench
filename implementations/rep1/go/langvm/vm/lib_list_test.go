package vm

import (
	"math/rand"
	"sort"
	"testing"
)

func TestListMutation(t *testing.T) {
	xs := call("listNew")
	wantInt(t, call("listLen", xs), 0)
	call("push", xs, Int(1))
	call("push", xs, Int(2))
	call("push", xs, Int(3))
	if !eqInts(listInts(xs), []int64{1, 2, 3}) {
		t.Fatal(listInts(xs))
	}
	wantInt(t, call("pop", xs), 3)
	wantInt(t, call("listLen", xs), 2)
	call("insert", xs, Int(0), Int(9))
	call("insert", xs, Int(3), Int(8))
	call("insert", xs, Int(2), Int(7))
	if !eqInts(listInts(xs), []int64{9, 1, 7, 2, 8}) {
		t.Fatal(listInts(xs))
	}
	wantPanic(t, "index out of bounds", "insert", xs, Int(6), Int(0))
	wantPanic(t, "index out of bounds", "insert", xs, Int(-1), Int(0))
	wantInt(t, call("removeAt", xs, Int(0)), 9)
	wantInt(t, call("removeAt", xs, Int(3)), 8)
	wantInt(t, call("removeAt", xs, Int(1)), 7)
	if !eqInts(listInts(xs), []int64{1, 2}) {
		t.Fatal(listInts(xs))
	}
	wantPanic(t, "index out of bounds", "removeAt", xs, Int(2))
	wantPanic(t, "index out of bounds", "removeAt", xs, Int(-1))
	wantInt(t, call("listFirst", xs), 1)
	wantInt(t, call("listLast", xs), 2)
	call("clear", xs)
	wantInt(t, call("listLen", xs), 0)
	wantPanic(t, "empty list", "pop", xs)
	wantPanic(t, "empty list", "listFirst", xs)
	wantPanic(t, "empty list", "listLast", xs)
	wantPanic(t, "index out of bounds", "removeAt", xs, Int(0))
	call("insert", xs, Int(0), Int(5))
	if !eqInts(listInts(xs), []int64{5}) {
		t.Fatal(listInts(xs))
	}
	// aliasing: the same object sees mutations
	ys := xs
	call("push", ys, Int(6))
	wantInt(t, call("listLen", xs), 2)
}

func TestListPure(t *testing.T) {
	a := intList(1, 2, 3)
	b := intList(4, 5)
	c := call("listConcat", a, b)
	if !eqInts(listInts(c), []int64{1, 2, 3, 4, 5}) || len(a.P.V) != 3 || len(b.P.V) != 2 {
		t.Error("concat")
	}
	call("push", c, Int(6))
	if len(a.P.V) != 3 {
		t.Error("concat aliases")
	}
	if !eqInts(listInts(call("listRepeat", Int(7), Int(3))), []int64{7, 7, 7}) {
		t.Error("repeat")
	}
	if len(call("listRepeat", Int(7), Int(0)).P.V) != 0 {
		t.Error("repeat 0")
	}
	wantPanic(t, "negative count", "listRepeat", Int(7), Int(-1))
	// repeat of a list shares the same object
	inner := intList(1)
	rr := call("listRepeat", inner, Int(2))
	if rr.P.V[0].P != rr.P.V[1].P {
		t.Error("repeat should share the same value")
	}
	if !eqInts(listInts(call("slice", intList(1, 2, 3, 4), Int(1), Int(3))), []int64{2, 3}) {
		t.Error("slice")
	}
	if len(call("slice", intList(1, 2), Int(2), Int(2)).P.V) != 0 || len(call("slice", intList(1, 2), Int(0), Int(0)).P.V) != 0 {
		t.Error("slice empty")
	}
	if !eqInts(listInts(call("slice", intList(1, 2), Int(0), Int(2))), []int64{1, 2}) {
		t.Error("slice all")
	}
	wantPanic(t, "index out of bounds", "slice", intList(1, 2), Int(-1), Int(1))
	wantPanic(t, "index out of bounds", "slice", intList(1, 2), Int(2), Int(1))
	wantPanic(t, "index out of bounds", "slice", intList(1, 2), Int(0), Int(3))
	cp := call("listCopy", a)
	call("push", cp, Int(0))
	if len(a.P.V) != 3 || len(cp.P.V) != 4 {
		t.Error("copy")
	}
	if !eqInts(listInts(call("reverseList", a)), []int64{3, 2, 1}) || !eqInts(listInts(a), []int64{1, 2, 3}) {
		t.Error("reverse")
	}
	if len(call("reverseList", List(nil)).P.V) != 0 {
		t.Error("reverse empty")
	}
	wantInt(t, call("listIndexOf", a, Int(3)), 2)
	wantInt(t, call("listIndexOf", a, Int(9)), -1)
	wantBool(t, call("listContains", a, Int(2)), true)
	wantBool(t, call("listContains", a, Int(0)), false)
	wantBool(t, call("listContains", strList("a", "b"), GoStr("b")), true)
	wantBool(t, call("listContains", strList("a", "b"), GoStr("c")), false)
	wantInt(t, call("listIndexOf", List([]Value{intList(1), intList(2, 3)}), intList(2, 3)), 1)
	wantInt(t, call("listIndexOf", List([]Value{Float(1), Float(2)}), Float(2)), 1)
	nan := call("nanF")
	wantInt(t, call("listIndexOf", List([]Value{nan}), nan), -1)
	wantInt(t, call("listIndexOf", List([]Value{Bool(false), Bool(true)}), Bool(true)), 1)
	wantInt(t, call("listIndexOf", List([]Value{Char('a'), Char('b')}), Char('b')), 1)
	wantInt(t, call("listIndexOf", List([]Value{Some(Int(1)), NoneV}), NoneV), 1)
	wantInt(t, call("listIndexOf", List([]Value{Some(Int(1)), NoneV}), Some(Int(1))), 0)

	z := call("listZip", intList(1, 2, 3), strList("a", "b"))
	if len(z.P.V) != 2 || z.P.V[1].P.V[0].N != 2 || gs(z.P.V[1].P.V[1]) != "b" || z.P.V[0].P.Kind != KTuple {
		t.Error("zip")
	}
	if len(call("listZip", intList(), intList(1)).P.V) != 0 {
		t.Error("zip empty")
	}
	fl := call("listFlatten", List([]Value{intList(1, 2), intList(), intList(3)}))
	if !eqInts(listInts(fl), []int64{1, 2, 3}) {
		t.Error("flatten")
	}
	if len(call("listFlatten", List(nil)).P.V) != 0 {
		t.Error("flatten empty")
	}
}

// Closure-taking built-ins on empty lists never call back.
func TestListHigherOrderEmpty(t *testing.T) {
	e := List(nil)
	f := Unit // never called
	if len(call("listMap", e, f).P.V) != 0 || len(call("listFilter", e, f).P.V) != 0 {
		t.Error("map/filter")
	}
	wantInt(t, call("listFold", e, Int(5), f), 5)
	wantBool(t, call("listAny", e, f), false)
	wantBool(t, call("listAll", e, f), true)
	if call("listFind", e, f).P.Var != VarNone {
		t.Error("find")
	}
	wantInt(t, call("listFindIndex", e, f), -1)
	if len(call("sortBy", e, f).P.V) != 0 {
		t.Error("sortBy empty")
	}
	one := call("sortBy", intList(4), f)
	if !eqInts(listInts(one), []int64{4}) {
		t.Error("sortBy one")
	}
}

type pair struct{ key, id int64 }

func TestMergeSortMatchesSpec(t *testing.T) {
	// Reference: literal transcription of the SPEC 15.6 pseudocode with a call log.
	ref := func(xs []Value, cmp func(a, b Value) int64) []Value {
		n := len(xs)
		src := append([]Value(nil), xs...)
		if n <= 1 {
			return src
		}
		dst := make([]Value, n)
		min := func(a, b int) int {
			if a < b {
				return a
			}
			return b
		}
		width := 1
		for width < n {
			i := 0
			for i < n {
				lo := i
				mid := min(i+width, n)
				hi := min(i+2*width, n)
				a, b, k := lo, mid, lo
				for a < mid && b < hi {
					if cmp(src[a], src[b]) <= 0 {
						dst[k] = src[a]
						a++
					} else {
						dst[k] = src[b]
						b++
					}
					k++
				}
				for a < mid {
					dst[k] = src[a]
					a++
					k++
				}
				for b < hi {
					dst[k] = src[b]
					b++
					k++
				}
				i += 2 * width
			}
			src, dst = dst, src
			width *= 2
		}
		return src
	}
	rng := rand.New(rand.NewSource(1))
	for iter := 0; iter < 300; iter++ {
		n := rng.Intn(40)
		xs := make([]Value, n)
		for i := range xs {
			xs[i] = Tuple([]Value{Int(int64(rng.Intn(6))), Int(int64(i))})
		}
		var log1, log2 [][2]int64
		mk := func(log *[][2]int64) func(a, b Value) int64 {
			return func(a, b Value) int64 {
				*log = append(*log, [2]int64{a.P.V[1].N, b.P.V[1].N})
				return a.P.V[0].N - b.P.V[0].N
			}
		}
		r1 := mergeSort(append([]Value(nil), xs...), mk(&log1))
		r2 := ref(xs, mk(&log2))
		if len(log1) != len(log2) {
			t.Fatalf("call counts differ %d %d", len(log1), len(log2))
		}
		for i := range log1 {
			if log1[i] != log2[i] {
				t.Fatalf("call order differs at %d", i)
			}
		}
		for i := range r1 {
			if r1[i].P != r2[i].P {
				t.Fatalf("result differs")
			}
		}
		// stable and sorted
		ids := make([]pair, n)
		for i, v := range r1 {
			ids[i] = pair{v.P.V[0].N, v.P.V[1].N}
		}
		if !sort.SliceIsSorted(ids, func(i, j int) bool {
			return ids[i].key < ids[j].key || (ids[i].key == ids[j].key && ids[i].id < ids[j].id)
		}) {
			t.Fatalf("not stably sorted: %v", ids)
		}
	}
	// a known call sequence: 3 elements
	xs := []Value{Int(3), Int(1), Int(2)}
	var calls [][2]int64
	out := mergeSort(append([]Value(nil), xs...), func(a, b Value) int64 {
		calls = append(calls, [2]int64{a.N, b.N})
		return a.N - b.N
	})
	// width 1: merge [3],[1] -> cmp(3,1); [2] alone. width 2: merge [1,3],[2] -> cmp(1,2), cmp(3,2)
	want := [][2]int64{{3, 1}, {1, 2}, {3, 2}}
	for i := range want {
		if calls[i] != want[i] {
			t.Errorf("calls %v, want %v", calls, want)
			break
		}
	}
	if !eqInts(listInts(List(out)), []int64{1, 2, 3}) {
		t.Error("sorted")
	}
}
