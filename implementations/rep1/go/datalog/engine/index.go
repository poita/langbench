package engine

// index is a hash index on a subset of a relation's columns. Tuples with the
// same key hash form a singly linked chain threaded through next, so adding a
// tuple is O(1) and the index is never rebuilt. Chains may mix keys that
// collide on the 64-bit hash; readers verify the key columns.
type index struct {
	rel    *relation
	mask   uint32
	cols   []int
	synced int // tuples [0, synced) are indexed

	keys  []uint64 // table of key hashes
	heads []int32  // id+1 of the newest tuple with that hash; 0 = empty slot
	tmask uint64
	count int
	next  []int32 // next[id] = id+1 of the previous tuple in the chain
}

func newIndex(r *relation, mask uint32) *index {
	ix := &index{rel: r, mask: mask}
	for c := 0; c < r.arity; c++ {
		if mask&(1<<c) != 0 {
			ix.cols = append(ix.cols, c)
		}
	}
	ix.keys = make([]uint64, 16)
	ix.heads = make([]int32, 16)
	ix.tmask = 15
	return ix
}

func (ix *index) sync() {
	r := ix.rel
	for id := ix.synced; id < r.n; id++ {
		t := r.tuple(id)
		var h uint64
		for _, c := range ix.cols {
			h = mix(h, t[c])
		}
		slot := ix.slot(h)
		if ix.heads[slot] == 0 {
			if (ix.count+1)*2 > len(ix.heads) {
				ix.grow()
				slot = ix.slot(h)
			}
			ix.keys[slot] = h
			ix.count++
		}
		ix.next = append(ix.next, ix.heads[slot])
		ix.heads[slot] = int32(id + 1)
	}
	ix.synced = r.n
}

// slot returns the table slot holding hash h, or the empty slot for it.
func (ix *index) slot(h uint64) uint64 {
	i := h & ix.tmask
	for ix.heads[i] != 0 && ix.keys[i] != h {
		i = (i + 1) & ix.tmask
	}
	return i
}

func (ix *index) grow() {
	oldKeys, oldHeads := ix.keys, ix.heads
	size := len(oldHeads) * 2
	ix.keys = make([]uint64, size)
	ix.heads = make([]int32, size)
	ix.tmask = uint64(size - 1)
	for i, hd := range oldHeads {
		if hd != 0 {
			s := ix.slot(oldKeys[i])
			ix.keys[s] = oldKeys[i]
			ix.heads[s] = hd
		}
	}
}

// head returns id+1 of the newest tuple whose key hashes to h, or 0.
func (ix *index) head(h uint64) int32 { return ix.heads[ix.slot(h)] }
