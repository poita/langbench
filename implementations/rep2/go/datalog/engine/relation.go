package engine

// A relation stores a set of fixed-arity tuples of interned constants (ids
// that are ranks in the constant order, so comparing ids compares
// constants). Tuples live in one flat slice in insertion order; a tuple's
// position in that order is its id. A hash set deduplicates insertions and
// per-access-pattern hash indexes (see index) serve joins.

type relation struct {
	arity int
	data  []uint32 // n tuples, arity values each
	n     int
	set   []int32 // open addressing: tuple id+1, 0 = empty
	// Delta bookkeeping used by semi-naive evaluation of the relation's
	// component: tuples [dlo,dhi) are the previous round's new tuples and
	// mark is the tuple count when that round ended.
	dlo, dhi, mark int
	indexes        map[uint32]*index // by bit mask of bound columns
}

func newRelation(arity int) *relation {
	return &relation{arity: arity, indexes: map[uint32]*index{}}
}

func hashVals(t []uint32) uint64 {
	h := uint64(0x9E3779B97F4A7C15)
	for _, v := range t {
		h = (h ^ uint64(v)) * 0xff51afd7ed558ccd
		h ^= h >> 32
	}
	h *= 0xc4ceb9fe1a85ec53
	h ^= h >> 29
	return h
}

func (r *relation) tuple(id int) []uint32 { return r.data[id*r.arity : (id+1)*r.arity] }

func equalVals(a, b []uint32) bool {
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// contains reports whether t is in the relation.
func (r *relation) contains(t []uint32) bool {
	if len(r.set) == 0 {
		return false
	}
	mask := uint64(len(r.set) - 1)
	for s := hashVals(t) & mask; ; s = (s + 1) & mask {
		v := r.set[s]
		if v == 0 {
			return false
		}
		if equalVals(r.tuple(int(v-1)), t) {
			return true
		}
	}
}

// insert adds t if absent and reports whether it was added. Indexes are not
// updated; they catch up in index.sync.
func (r *relation) insert(t []uint32) bool {
	if (r.n+1)*2 > len(r.set) {
		r.growSet()
	}
	mask := uint64(len(r.set) - 1)
	s := hashVals(t) & mask
	for ; ; s = (s + 1) & mask {
		v := r.set[s]
		if v == 0 {
			break
		}
		if equalVals(r.tuple(int(v-1)), t) {
			return false
		}
	}
	r.data = append(r.data, t...)
	r.n++
	r.set[s] = int32(r.n)
	return true
}

func (r *relation) growSet() {
	size := max(16, len(r.set)*2)
	r.set = make([]int32, size)
	mask := uint64(size - 1)
	for id := 0; id < r.n; id++ {
		s := hashVals(r.tuple(id)) & mask
		for r.set[s] != 0 {
			s = (s + 1) & mask
		}
		r.set[s] = int32(id + 1)
	}
}

// getIndex returns the index on the columns in mask (bit i = column i),
// creating an empty one if needed.
func (r *relation) getIndex(mask uint32) *index {
	if ix, ok := r.indexes[mask]; ok {
		return ix
	}
	ix := &index{}
	for c := 0; c < r.arity; c++ {
		if mask&(1<<c) != 0 {
			ix.cols = append(ix.cols, c)
		}
	}
	r.indexes[mask] = ix
	return ix
}

// index is a hash index over a subset of columns. Tuples with equal values
// in those columns form a chain in ascending id order, so a reader that only
// wants tuples below some id stops at the first id past the limit. An index
// is only ever extended (sync), never rebuilt, so its total maintenance cost
// is linear in the relation.
type index struct {
	cols  []int
	slots []slot
	used  int
	next  []int32 // next[id] = id+1 of the next tuple in id's chain, 0 = end
	upto  int     // tuples [0,upto) are indexed
}

type slot struct{ head, tail int32 } // tuple id+1; head == 0 means empty

func (ix *index) keyOf(r *relation, id int, buf []uint32) []uint32 {
	t := r.tuple(id)
	buf = buf[:0]
	for _, c := range ix.cols {
		buf = append(buf, t[c])
	}
	return buf
}

func (ix *index) sameKey(r *relation, id int, key []uint32) bool {
	t := r.tuple(id)
	for i, c := range ix.cols {
		if t[c] != key[i] {
			return false
		}
	}
	return true
}

// sync adds the relation's tuples not yet indexed.
func (ix *index) sync(r *relation) {
	if ix.upto == r.n {
		return
	}
	for len(ix.next) < r.n {
		ix.next = append(ix.next, 0)
	}
	var kb [8]uint32
	for id := ix.upto; id < r.n; id++ {
		if (ix.used+1)*2 > len(ix.slots) {
			ix.grow(r)
		}
		key := ix.keyOf(r, id, kb[:0])
		mask := uint64(len(ix.slots) - 1)
		s := hashVals(key) & mask
		for {
			sl := &ix.slots[s]
			if sl.head == 0 {
				sl.head, sl.tail = int32(id+1), int32(id+1)
				ix.used++
				break
			}
			if ix.sameKey(r, int(sl.head-1), key) {
				ix.next[sl.tail-1] = int32(id + 1)
				sl.tail = int32(id + 1)
				break
			}
			s = (s + 1) & mask
		}
		ix.upto = id + 1
	}
}

func (ix *index) grow(r *relation) {
	old := ix.slots
	ix.slots = make([]slot, max(16, len(old)*2))
	mask := uint64(len(ix.slots) - 1)
	var kb [8]uint32
	for _, sl := range old {
		if sl.head == 0 {
			continue
		}
		s := hashVals(ix.keyOf(r, int(sl.head-1), kb[:0])) & mask
		for ix.slots[s].head != 0 {
			s = (s + 1) & mask
		}
		ix.slots[s] = sl
	}
}

// find returns id+1 of the first tuple whose indexed columns equal key, or 0.
func (ix *index) find(r *relation, key []uint32) int32 {
	if len(ix.slots) == 0 {
		return 0
	}
	mask := uint64(len(ix.slots) - 1)
	for s := hashVals(key) & mask; ; s = (s + 1) & mask {
		sl := ix.slots[s]
		if sl.head == 0 {
			return 0
		}
		if ix.sameKey(r, int(sl.head-1), key) {
			return sl.head
		}
	}
}
