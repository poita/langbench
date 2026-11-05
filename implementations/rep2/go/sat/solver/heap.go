package solver

// varHeap is an indexed binary max-heap of variables ordered by activity.
// pos[v] is the index of v in heap, or -1 when v is not in the heap.
type varHeap struct {
	heap []int32
	pos  []int32
	act  *[]float64
}

func (h *varHeap) grow(n int) {
	for len(h.pos) < n {
		h.pos = append(h.pos, -1)
	}
}

func (h *varHeap) empty() bool           { return len(h.heap) == 0 }
func (h *varHeap) contains(v int32) bool { return h.pos[v] >= 0 }

func (h *varHeap) insert(v int32) {
	if h.pos[v] >= 0 {
		return
	}
	h.pos[v] = int32(len(h.heap))
	h.heap = append(h.heap, v)
	h.up(int(h.pos[v]))
}

// increased restores the heap order after v's activity has grown.
func (h *varHeap) increased(v int32) {
	if h.pos[v] >= 0 {
		h.up(int(h.pos[v]))
	}
}

// pop removes and returns the variable with the highest activity.
func (h *varHeap) pop() int32 {
	top := h.heap[0]
	last := h.heap[len(h.heap)-1]
	h.heap = h.heap[:len(h.heap)-1]
	h.pos[top] = -1
	if len(h.heap) > 0 {
		h.heap[0] = last
		h.pos[last] = 0
		h.down(0)
	}
	return top
}

func (h *varHeap) up(i int) {
	act := *h.act
	x := h.heap[i]
	ax := act[x]
	for i > 0 {
		p := (i - 1) >> 1
		if act[h.heap[p]] >= ax {
			break
		}
		h.heap[i] = h.heap[p]
		h.pos[h.heap[i]] = int32(i)
		i = p
	}
	h.heap[i] = x
	h.pos[x] = int32(i)
}

func (h *varHeap) down(i int) {
	act := *h.act
	n := len(h.heap)
	x := h.heap[i]
	ax := act[x]
	for {
		c := 2*i + 1
		if c >= n {
			break
		}
		if r := c + 1; r < n && act[h.heap[r]] > act[h.heap[c]] {
			c = r
		}
		if act[h.heap[c]] <= ax {
			break
		}
		h.heap[i] = h.heap[c]
		h.pos[h.heap[i]] = int32(i)
		i = c
	}
	h.heap[i] = x
	h.pos[x] = int32(i)
}
