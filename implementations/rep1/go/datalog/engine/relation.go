// Package engine evaluates stratified Datalog programs bottom-up with
// semi-naive evaluation over hash-indexed relations.
//
// Constants are interned to dense int32 identifiers whose numeric order is the
// constants' total order, so comparisons and sorting work on plain integers.
package engine

// Relation storage: tuples live in one flat slice, tuple i at
// data[i*arity : (i+1)*arity]. A hash set over whole tuples provides
// deduplication and membership; secondary hash indexes (see index.go) serve
// joins. Tuples are never removed, so a tuple's id is stable and the tuples
// derived in a round form a contiguous id range.

type relation struct {
	arity int
	data  []int32
	n     int // number of tuples

	set     []int32 // open-addressing table of tuple id+1; 0 = empty
	setMask uint64

	indexes []*index // one per access pattern (bitmask of bound columns)
	synced  int      // tuples [0, synced) are visible to joins and are in every index

	// delta range for the semi-naive round in progress
	dlo, dhi int
}

func newRelation(arity int) *relation {
	r := &relation{arity: arity}
	r.set = make([]int32, 16)
	r.setMask = 15
	return r
}

func (r *relation) tuple(id int) []int32 { return r.data[id*r.arity : (id+1)*r.arity] }

const prime = 0x9E3779B97F4A7C15

func mix(h uint64, v int32) uint64 {
	h = (h + uint64(uint32(v)) + 1) * prime
	return h ^ h>>29
}

func hashTuple(t []int32) uint64 {
	var h uint64
	for _, v := range t {
		h = mix(h, v)
	}
	return h
}

// find returns the id of tuple t, or -1.
func (r *relation) find(t []int32) int {
	for i := hashTuple(t) & r.setMask; ; i = (i + 1) & r.setMask {
		e := r.set[i]
		if e == 0 {
			return -1
		}
		if equal(r.tuple(int(e-1)), t) {
			return int(e - 1)
		}
	}
}

// insert adds t if absent and reports whether it was added.
func (r *relation) insert(t []int32) bool {
	if (r.n+1)*2 > len(r.set) {
		r.growSet()
	}
	i := hashTuple(t) & r.setMask
	for ; ; i = (i + 1) & r.setMask {
		e := r.set[i]
		if e == 0 {
			break
		}
		if equal(r.tuple(int(e-1)), t) {
			return false
		}
	}
	r.data = append(r.data, t...)
	r.n++
	r.set[i] = int32(r.n)
	return true
}

func (r *relation) growSet() {
	size := len(r.set) * 2
	r.set = make([]int32, size)
	r.setMask = uint64(size - 1)
	for id := 0; id < r.n; id++ {
		i := hashTuple(r.tuple(id)) & r.setMask
		for r.set[i] != 0 {
			i = (i + 1) & r.setMask
		}
		r.set[i] = int32(id + 1)
	}
}

func equal(a, b []int32) bool {
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// indexFor returns the index on the columns in mask, creating it if needed.
func (r *relation) indexFor(mask uint32) *index {
	for _, ix := range r.indexes {
		if ix.mask == mask {
			return ix
		}
	}
	ix := newIndex(r, mask)
	r.indexes = append(r.indexes, ix)
	return ix
}

// sync makes all tuples inserted so far visible to joins and adds them to
// every index. Each tuple is added to each index exactly once over a run.
func (r *relation) sync() {
	for _, ix := range r.indexes {
		ix.sync()
	}
	r.synced = r.n
}
