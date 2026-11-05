package sat

// varHeap is an indexed binary max-heap of variables ordered by activity.
// The tie-breaking rules (strict comparisons in sift-up/sift-down) are part
// of the solver's deterministic behaviour.
type varHeap struct {
	act   *[]float64 // shared with the solver
	items []int32
	pos   []int32 // position of each variable in items, or -1
}

func newVarHeap(act *[]float64, n int) *varHeap {
	h := &varHeap{act: act, pos: make([]int32, n)}
	for i := range h.pos {
		h.pos[i] = -1
	}
	return h
}

func (h *varHeap) contains(v int32) bool { return h.pos[v] >= 0 }

func (h *varHeap) insert(v int32) {
	h.pos[v] = int32(len(h.items))
	h.items = append(h.items, v)
	h.up(int(h.pos[v]))
}

// increased restores the heap order after the activity of v has grown.
func (h *varHeap) increased(v int32) {
	if p := h.pos[v]; p >= 0 {
		h.up(int(p))
	}
}

func (h *varHeap) pop() int32 {
	top := h.items[0]
	last := h.items[len(h.items)-1]
	h.items = h.items[:len(h.items)-1]
	h.pos[top] = -1
	if len(h.items) > 0 {
		h.items[0] = last
		h.pos[last] = 0
		h.down(0)
	}
	return top
}

func (h *varHeap) up(i int) {
	act := *h.act
	x := h.items[i]
	ax := act[x]
	for i > 0 {
		p := (i - 1) >> 1
		if act[h.items[p]] >= ax {
			break
		}
		h.items[i] = h.items[p]
		h.pos[h.items[i]] = int32(i)
		i = p
	}
	h.items[i] = x
	h.pos[x] = int32(i)
}

func (h *varHeap) down(i int) {
	act := *h.act
	x := h.items[i]
	ax := act[x]
	n := len(h.items)
	for {
		c := 2*i + 1
		if c >= n {
			break
		}
		if r := c + 1; r < n && act[h.items[r]] > act[h.items[c]] {
			c = r
		}
		if act[h.items[c]] <= ax {
			break
		}
		h.items[i] = h.items[c]
		h.pos[h.items[i]] = int32(i)
		i = c
	}
	h.items[i] = x
	h.pos[x] = int32(i)
}
