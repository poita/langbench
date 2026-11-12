package sat

// varHeap is a binary max-heap of variables ordered by activity. It supports
// O(log n) insertion, removal of the maximum and key increase.
type varHeap struct {
	act     *[]float64 // shared with the solver
	heap    []int
	indices []int // position of each variable in heap, or -1
}

func (h *varHeap) grow(n int) {
	for len(h.indices) < n {
		h.indices = append(h.indices, -1)
	}
}

func (h *varHeap) contains(v int) bool { return h.indices[v] >= 0 }
func (h *varHeap) empty() bool         { return len(h.heap) == 0 }
func (h *varHeap) less(a, b int) bool  { return (*h.act)[a] > (*h.act)[b] }

func (h *varHeap) insert(v int) {
	h.indices[v] = len(h.heap)
	h.heap = append(h.heap, v)
	h.up(h.indices[v])
}

// increased restores the heap order after the activity of v grew.
func (h *varHeap) increased(v int) {
	if h.contains(v) {
		h.up(h.indices[v])
	}
}

func (h *varHeap) removeMax() int {
	top := h.heap[0]
	last := h.heap[len(h.heap)-1]
	h.heap = h.heap[:len(h.heap)-1]
	h.indices[top] = -1
	if len(h.heap) > 0 {
		h.heap[0] = last
		h.indices[last] = 0
		h.down(0)
	}
	return top
}

func (h *varHeap) up(i int) {
	v := h.heap[i]
	for i > 0 {
		p := (i - 1) >> 1
		if !h.less(v, h.heap[p]) {
			break
		}
		h.heap[i] = h.heap[p]
		h.indices[h.heap[i]] = i
		i = p
	}
	h.heap[i] = v
	h.indices[v] = i
}

func (h *varHeap) down(i int) {
	v := h.heap[i]
	n := len(h.heap)
	for {
		c := 2*i + 1
		if c >= n {
			break
		}
		if c+1 < n && h.less(h.heap[c+1], h.heap[c]) {
			c++
		}
		if !h.less(h.heap[c], v) {
			break
		}
		h.heap[i] = h.heap[c]
		h.indices[h.heap[i]] = i
		i = c
	}
	h.heap[i] = v
	h.indices[v] = i
}
