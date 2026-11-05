package store

// Index maps the values at a fixed set of argument positions (the key) to the
// positions of all tuples having those values, in ascending order. It is
// extended incrementally by Update and never rebuilt.
type Index struct {
	rel     *Relation
	cols    []int
	table   []int32 // open addressing: group + 1, 0 = empty
	head    []int32 // per group: first tuple position
	tail    []int32 // per group: last tuple position
	next    []int32 // per tuple position: next position in the same group, or -1
	indexed int     // tuples [0, indexed) are in the index
	scratch [8]int32
}

func newIndex(r *Relation, cols []int) *Index {
	return &Index{rel: r, cols: append([]int(nil), cols...), table: make([]int32, 16)}
}

// Cols returns the indexed argument positions.
func (ix *Index) Cols() []int { return ix.cols }

// Update indexes the tuples appended to the relation since the last call.
func (ix *Index) Update() {
	r := ix.rel
	for ; ix.indexed < r.n; ix.indexed++ {
		pos := int32(ix.indexed)
		row := r.Tuple(ix.indexed)
		key := ix.scratch[:len(ix.cols)]
		for i, c := range ix.cols {
			key[i] = row[c]
		}
		ix.next = append(ix.next, -1)
		if g := ix.find(key); g >= 0 {
			ix.next[ix.tail[g]] = pos
			ix.tail[g] = pos
			continue
		}
		if (len(ix.head)+1)*2 > len(ix.table) {
			ix.grow()
		}
		mask := uint64(len(ix.table) - 1)
		s := hash(key) & mask
		for ix.table[s] != 0 {
			s = (s + 1) & mask
		}
		ix.head = append(ix.head, pos)
		ix.tail = append(ix.tail, pos)
		ix.table[s] = int32(len(ix.head))
	}
}

// find returns the group for key, or -1.
func (ix *Index) find(key []int32) int {
	mask := uint64(len(ix.table) - 1)
	for s := hash(key) & mask; ; s = (s + 1) & mask {
		e := ix.table[s]
		if e == 0 {
			return -1
		}
		row := ix.rel.Tuple(int(ix.head[e-1]))
		ok := true
		for i, c := range ix.cols {
			if row[c] != key[i] {
				ok = false
				break
			}
		}
		if ok {
			return int(e - 1)
		}
	}
}

func (ix *Index) grow() {
	table := make([]int32, len(ix.table)*2)
	mask := uint64(len(table) - 1)
	var key [8]int32
	for g, p := range ix.head {
		row := ix.rel.Tuple(int(p))
		for i, c := range ix.cols {
			key[i] = row[c]
		}
		s := hash(key[:len(ix.cols)]) & mask
		for table[s] != 0 {
			s = (s + 1) & mask
		}
		table[s] = int32(g + 1)
	}
	ix.table = table
}

// First returns the position of the first tuple whose indexed components
// equal key (given in the order of Cols), or -1 if there is none. Subsequent
// matches, in ascending position order, follow via Next.
func (ix *Index) First(key []int32) int32 {
	if g := ix.find(key); g >= 0 {
		return ix.head[g]
	}
	return -1
}

// Next returns the position of the next tuple in the same group as pos, or -1.
func (ix *Index) Next(pos int32) int32 { return ix.next[pos] }
