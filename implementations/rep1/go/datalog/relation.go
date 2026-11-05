package datalog

// relation is an append-only set of fixed-arity tuples of constant ids.
//
// Tuples are stored contiguously in insertion order, so a tuple has a stable
// position. An open-addressing hash set over the whole tuple deduplicates
// inserts and answers membership. Hash indexes on subsets of the columns are
// created on demand (see index) and extended incrementally.
type relation struct {
	arity   int
	data    []int32 // n*arity ids
	n       int
	table   []int32 // open-addressing set: tuple position+1, 0 = empty
	indexes map[uint64]*index
}

func newRelation(arity int) *relation {
	return &relation{arity: arity, indexes: map[uint64]*index{}}
}

// tuple returns the tuple at pos. The slice aliases the relation's storage and
// is invalidated by add.
func (r *relation) tuple(pos int) []int32 {
	return r.data[pos*r.arity : (pos+1)*r.arity : (pos+1)*r.arity]
}

func hashStep(h uint64, v int32) uint64 {
	h = (h ^ uint64(uint32(v))) * 0x9E3779B97F4A7C15
	return h ^ h>>29
}

const hashSeed = 0xcbf29ce484222325

func hashTuple(t []int32) uint64 {
	h := uint64(hashSeed)
	for _, v := range t {
		h = hashStep(h, v)
	}
	return h
}

func equalTuples(a, b []int32) bool {
	for i, v := range a {
		if b[i] != v {
			return false
		}
	}
	return true
}

// contains reports whether t is in the relation.
func (r *relation) contains(t []int32) bool {
	if r.n == 0 {
		return false
	}
	mask := uint64(len(r.table) - 1)
	for s := hashTuple(t) & mask; ; s = (s + 1) & mask {
		e := r.table[s]
		if e == 0 {
			return false
		}
		if equalTuples(r.tuple(int(e-1)), t) {
			return true
		}
	}
}

// add inserts t and reports whether it was new.
func (r *relation) add(t []int32) bool {
	if (r.n+1)*2 > len(r.table) {
		r.growTable()
	}
	mask := uint64(len(r.table) - 1)
	s := hashTuple(t) & mask
	for ; ; s = (s + 1) & mask {
		e := r.table[s]
		if e == 0 {
			break
		}
		if equalTuples(r.tuple(int(e-1)), t) {
			return false
		}
	}
	r.data = append(r.data, t...)
	r.n++
	r.table[s] = int32(r.n)
	return true
}

func (r *relation) growTable() {
	size := max(16, len(r.table)*2)
	r.table = make([]int32, size)
	mask := uint64(size - 1)
	for pos := 0; pos < r.n; pos++ {
		s := hashTuple(r.tuple(pos)) & mask
		for r.table[s] != 0 {
			s = (s + 1) & mask
		}
		r.table[s] = int32(pos + 1)
	}
}

// index returns the index on the given columns (a bitmask of argument
// positions), creating it if needed. A new index is empty until sync.
func (r *relation) index(cols uint64) *index {
	if ix, ok := r.indexes[cols]; ok {
		return ix
	}
	ix := &index{rel: r, buckets: make([]int32, 16)}
	for c := 0; c < r.arity; c++ {
		if cols>>c&1 != 0 {
			ix.cols = append(ix.cols, c)
		}
	}
	r.indexes[cols] = ix
	return ix
}

// index maps the values of a fixed set of columns to the positions of all
// tuples with those values. The positions of one key form a linked list
// threaded through next in ascending order, so a scan can stop at the first
// position beyond a snapshot bound.
type index struct {
	rel     *relation
	cols    []int
	buckets []int32 // head of entry chain, entry id+1; 0 = empty
	entries []indexEntry
	next    []int32 // next[pos] = next tuple position with the same key, or -1
	done    int     // tuples [0, done) are indexed
}

type indexEntry struct {
	hash        uint32
	first, last int32
	chain       int32 // next entry in the same bucket, id+1
}

// sync indexes the tuples appended since the last call.
func (ix *index) sync() {
	for pos := ix.done; pos < ix.rel.n; pos++ {
		ix.insert(pos)
	}
	ix.done = ix.rel.n
}

func (ix *index) tupleHash(t []int32) uint64 {
	h := uint64(hashSeed)
	for _, c := range ix.cols {
		h = hashStep(h, t[c])
	}
	return h
}

func (ix *index) insert(pos int) {
	t := ix.rel.tuple(pos)
	h := ix.tupleHash(t)
	ix.next = append(ix.next, -1)
	b := h & uint64(len(ix.buckets)-1)
	for e := ix.buckets[b]; e != 0; e = ix.entries[e-1].chain {
		en := &ix.entries[e-1]
		if en.hash == uint32(h) && ix.sameKey(ix.rel.tuple(int(en.first)), t) {
			ix.next[en.last] = int32(pos)
			en.last = int32(pos)
			return
		}
	}
	if len(ix.entries) >= len(ix.buckets) {
		ix.growBuckets()
		b = h & uint64(len(ix.buckets)-1)
	}
	ix.entries = append(ix.entries, indexEntry{hash: uint32(h), first: int32(pos), last: int32(pos), chain: ix.buckets[b]})
	ix.buckets[b] = int32(len(ix.entries))
}

func (ix *index) growBuckets() {
	ix.buckets = make([]int32, len(ix.buckets)*2)
	mask := uint64(len(ix.buckets) - 1)
	for i := range ix.entries {
		en := &ix.entries[i]
		b := uint64(en.hash) & mask
		en.chain = ix.buckets[b]
		ix.buckets[b] = int32(i + 1)
	}
}

func (ix *index) sameKey(a, b []int32) bool {
	for _, c := range ix.cols {
		if a[c] != b[c] {
			return false
		}
	}
	return true
}

// find returns the first position whose key columns equal key (given in
// column order), or -1. Follow ix.next for the remaining positions.
func (ix *index) find(key []int32) int32 {
	h := uint64(hashSeed)
	for _, v := range key {
		h = hashStep(h, v)
	}
	for e := ix.buckets[h&uint64(len(ix.buckets)-1)]; e != 0; {
		en := &ix.entries[e-1]
		if en.hash == uint32(h) {
			t := ix.rel.tuple(int(en.first))
			match := true
			for i, c := range ix.cols {
				if t[c] != key[i] {
					match = false
					break
				}
			}
			if match {
				return en.first
			}
		}
		e = en.chain
	}
	return -1
}
