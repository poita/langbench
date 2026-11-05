// Package store provides the storage layer of the Datalog engine: relations
// held as append-only arrays of fixed-arity integer tuples, with a hash set
// for deduplication and lazily built, incrementally maintained hash indexes.
//
// A tuple has a stable position (its insertion order). Positions are what
// indexes store, so a range of positions [lo, hi) is a cheap, immutable
// snapshot of a relation: tuples appended later never change it.
package store

// Relation is a set of tuples of one fixed arity. It is not safe for
// concurrent use.
type Relation struct {
	arity   int
	data    []int32 // flat tuples, stride = arity
	n       int     // number of tuples
	table   []int32 // open-addressing set: tuple position + 1, 0 = empty
	indexes map[uint32]*Index
}

// NewRelation returns an empty relation whose tuples have the given arity.
func NewRelation(arity int) *Relation {
	return &Relation{arity: arity, table: make([]int32, 16)}
}

// Arity returns the number of components in each tuple.
func (r *Relation) Arity() int { return r.arity }

// Len returns the number of tuples.
func (r *Relation) Len() int { return r.n }

// Tuple returns the tuple at position i. The result aliases internal storage
// and must not be modified.
func (r *Relation) Tuple(i int) []int32 {
	return r.data[i*r.arity : (i+1)*r.arity : (i+1)*r.arity]
}

// Contains reports whether t is in the relation.
func (r *Relation) Contains(t []int32) bool {
	mask := uint64(len(r.table) - 1)
	for s := hash(t) & mask; ; s = (s + 1) & mask {
		e := r.table[s]
		if e == 0 {
			return false
		}
		if equal(r.Tuple(int(e-1)), t) {
			return true
		}
	}
}

// Insert adds t to the relation and reports whether it was new. The tuple is
// copied.
func (r *Relation) Insert(t []int32) bool {
	if (r.n+1)*2 > len(r.table) {
		r.grow()
	}
	mask := uint64(len(r.table) - 1)
	s := hash(t) & mask
	for ; ; s = (s + 1) & mask {
		e := r.table[s]
		if e == 0 {
			break
		}
		if equal(r.Tuple(int(e-1)), t) {
			return false
		}
	}
	r.data = append(r.data, t...)
	r.n++
	r.table[s] = int32(r.n)
	return true
}

func (r *Relation) grow() {
	table := make([]int32, len(r.table)*2)
	mask := uint64(len(table) - 1)
	for i := 0; i < r.n; i++ {
		s := hash(r.Tuple(i)) & mask
		for table[s] != 0 {
			s = (s + 1) & mask
		}
		table[s] = int32(i + 1)
	}
	r.table = table
}

// Index returns the hash index over the given argument positions, creating
// it (empty, not yet populated) on first use. cols must be strictly
// ascending and non-empty. The caller must call Update before reading it.
func (r *Relation) Index(cols []int) *Index {
	var m uint32
	for _, c := range cols {
		m |= 1 << uint(c)
	}
	if ix, ok := r.indexes[m]; ok {
		return ix
	}
	if r.indexes == nil {
		r.indexes = make(map[uint32]*Index)
	}
	ix := newIndex(r, cols)
	r.indexes[m] = ix
	return ix
}

func hash(t []int32) uint64 {
	h := uint64(len(t))
	for _, v := range t {
		h = (h ^ uint64(uint32(v))) * 0x9E3779B97F4A7C15
		h ^= h >> 29
	}
	return h
}

func equal(a, b []int32) bool {
	for i, v := range a {
		if b[i] != v {
			return false
		}
	}
	return true
}
