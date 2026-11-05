// Package engine evaluates a checked Datalog program bottom-up with
// semi-naive evaluation over hash-indexed relations of interned constants.
package engine

// Relation is a set of fixed-arity tuples of constant ids. Tuples are stored
// contiguously in insertion order, so a tuple has a stable position, and an
// open-addressing hash set over whole tuples deduplicates inserts and answers
// membership tests.
type Relation struct {
	arity int
	data  []int32 // n*arity ids
	n     int
	table []int32 // open-addressing slots holding position+1; 0 = empty
	mask  uint64
	idx   map[uint32]*Index // by bitmask of indexed columns
}

func newRelation(arity int) *Relation {
	return &Relation{
		arity: arity,
		table: make([]int32, 16),
		mask:  15,
		idx:   map[uint32]*Index{},
	}
}

// Arity returns the number of columns.
func (r *Relation) Arity() int { return r.arity }

// Len returns the number of tuples.
func (r *Relation) Len() int { return r.n }

// Tuple returns the i-th tuple in insertion order. The slice aliases the
// relation's storage and must not be modified.
func (r *Relation) Tuple(i int) []int32 { return r.data[i*r.arity : (i+1)*r.arity] }

func hashIDs(t []int32) uint64 {
	h := uint64(0x9E3779B97F4A7C15)
	for _, v := range t {
		h = (h ^ uint64(uint32(v))) * 0xff51afd7ed558ccd
		h ^= h >> 29
	}
	return h
}

// Contains reports whether t is in the relation.
func (r *Relation) Contains(t []int32) bool {
	_, found := r.find(t, hashIDs(t))
	return found
}

func (r *Relation) find(t []int32, h uint64) (slot uint64, found bool) {
	a := r.arity
	for s := h & r.mask; ; s = (s + 1) & r.mask {
		e := r.table[s]
		if e == 0 {
			return s, false
		}
		base := int(e-1) * a
		row := r.data[base : base+a]
		eq := true
		for i, v := range row {
			if v != t[i] {
				eq = false
				break
			}
		}
		if eq {
			return s, true
		}
	}
}

// Add inserts t and reports whether it was new.
func (r *Relation) Add(t []int32) bool {
	h := hashIDs(t)
	slot, found := r.find(t, h)
	if found {
		return false
	}
	r.data = append(r.data, t...)
	r.n++
	r.table[slot] = int32(r.n)
	if uint64(r.n)*2 > r.mask {
		r.grow()
	}
	return true
}

func (r *Relation) grow() {
	size := (r.mask + 1) * 2
	r.table = make([]int32, size)
	r.mask = size - 1
	for i := 0; i < r.n; i++ {
		s := hashIDs(r.Tuple(i)) & r.mask
		for r.table[s] != 0 {
			s = (s + 1) & r.mask
		}
		r.table[s] = int32(i + 1)
	}
}

// index returns the index over the given columns (ascending), creating it if
// needed. A new index is empty until Update is called.
func (r *Relation) index(cols []int) *Index {
	var m uint32
	for _, c := range cols {
		m |= 1 << c
	}
	if ix, ok := r.idx[m]; ok {
		return ix
	}
	ix := &Index{rel: r, cols: append([]int(nil), cols...), table: make([]int32, 16), mask: 15}
	r.idx[m] = ix
	return ix
}

// Index maps the values of a fixed set of columns to the positions of the
// matching tuples, in ascending order. Entries for one key form a linked list
// threaded through next, so appending a tuple is O(1) and the list can be
// walked until a position outside the caller's snapshot is reached.
type Index struct {
	rel   *Relation
	cols  []int
	done  int     // tuples [0,done) are indexed
	table []int32 // open addressing: bucket+1
	mask  uint64
	keys  []int32 // bucket b's key is keys[b*len(cols):]
	head  []int32 // first position of bucket
	tail  []int32 // last position of bucket
	next  []int32 // next[pos] = next position with the same key, or -1
}

func (ix *Index) keyOf(pos int, buf *[6]int32) []int32 {
	t := ix.rel.Tuple(pos)
	k := buf[:len(ix.cols)]
	for i, c := range ix.cols {
		k[i] = t[c]
	}
	return k
}

func (ix *Index) probe(key []int32, h uint64) (slot uint64, bucket int) {
	w := len(ix.cols)
	for s := h & ix.mask; ; s = (s + 1) & ix.mask {
		e := ix.table[s]
		if e == 0 {
			return s, -1
		}
		b := int(e - 1)
		stored := ix.keys[b*w : b*w+w]
		eq := true
		for i, v := range stored {
			if v != key[i] {
				eq = false
				break
			}
		}
		if eq {
			return s, b
		}
	}
}

// Update indexes the tuples appended to the relation since the last call.
func (ix *Index) Update() {
	var buf [6]int32
	n := ix.rel.n
	for pos := ix.done; pos < n; pos++ {
		key := ix.keyOf(pos, &buf)
		slot, b := ix.probe(key, hashIDs(key))
		ix.next = append(ix.next, -1)
		if b >= 0 {
			ix.next[ix.tail[b]] = int32(pos)
			ix.tail[b] = int32(pos)
			continue
		}
		ix.keys = append(ix.keys, key...)
		ix.head = append(ix.head, int32(pos))
		ix.tail = append(ix.tail, int32(pos))
		ix.table[slot] = int32(len(ix.head))
		if uint64(len(ix.head))*2 > ix.mask {
			ix.grow()
		}
	}
	ix.done = n
}

func (ix *Index) grow() {
	size := (ix.mask + 1) * 2
	ix.table = make([]int32, size)
	ix.mask = size - 1
	w := len(ix.cols)
	for b := range ix.head {
		s := hashIDs(ix.keys[b*w:b*w+w]) & ix.mask
		for ix.table[s] != 0 {
			s = (s + 1) & ix.mask
		}
		ix.table[s] = int32(b + 1)
	}
}

// first returns the first position whose columns equal key, or -1.
func (ix *Index) first(key []int32) int32 {
	_, b := ix.probe(key, hashIDs(key))
	if b < 0 {
		return -1
	}
	return ix.head[b]
}
