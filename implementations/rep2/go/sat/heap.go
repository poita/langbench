package sat

// varHeap is a binary max-heap of variables keyed by activity, with an index
// so that membership tests and key increases take O(log n).
type varHeap struct {
	act   *[]float64 // shared with the solver
	items []Var
	pos   []int32 // position in items, or -1 when absent
}

func (h *varHeap) grow(n int) {
	for len(h.pos) < n {
		h.pos = append(h.pos, -1)
	}
}

func (h *varHeap) less(a, b Var) bool { return (*h.act)[a] > (*h.act)[b] }

func (h *varHeap) contains(v Var) bool { return h.pos[v] >= 0 }

func (h *varHeap) empty() bool { return len(h.items) == 0 }

func (h *varHeap) insert(v Var) {
	if h.contains(v) {
		return
	}
	h.pos[v] = int32(len(h.items))
	h.items = append(h.items, v)
	h.up(int(h.pos[v]))
}

// increased restores the heap order after the activity of v went up.
func (h *varHeap) increased(v Var) {
	if h.contains(v) {
		h.up(int(h.pos[v]))
	}
}

func (h *varHeap) removeMax() Var {
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
	v := h.items[i]
	for i > 0 {
		p := (i - 1) >> 1
		if !h.less(v, h.items[p]) {
			break
		}
		h.items[i] = h.items[p]
		h.pos[h.items[i]] = int32(i)
		i = p
	}
	h.items[i] = v
	h.pos[v] = int32(i)
}

func (h *varHeap) down(i int) {
	v := h.items[i]
	n := len(h.items)
	for {
		c := 2*i + 1
		if c >= n {
			break
		}
		if c+1 < n && h.less(h.items[c+1], h.items[c]) {
			c++
		}
		if !h.less(h.items[c], v) {
			break
		}
		h.items[i] = h.items[c]
		h.pos[h.items[i]] = int32(i)
		i = c
	}
	h.items[i] = v
	h.pos[v] = int32(i)
}
