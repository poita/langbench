package solver

// varHeap is an indexed binary max-heap of variables ordered by activity.
// The tie-breaking rules are part of the solver's deterministic behaviour:
// sift-up stops when the parent's activity is >= the element's, sift-down
// moves to the right child only if it is strictly greater than the left one
// and stops when the child is <= the element.
type varHeap struct {
	act  *[]float64 // shared with the solver
	heap []int32    // heap order
	pos  []int32    // position of each variable in heap, or -1
}

func (h *varHeap) grow(n int) {
	for len(h.pos) < n {
		h.pos = append(h.pos, -1)
	}
}

func (h *varHeap) contains(v int32) bool { return h.pos[v] >= 0 }

func (h *varHeap) insert(v int32) {
	if h.pos[v] >= 0 {
		return
	}
	h.pos[v] = int32(len(h.heap))
	h.heap = append(h.heap, v)
	h.siftUp(int(h.pos[v]))
}

// increased restores the heap property after v's activity grew.
func (h *varHeap) increased(v int32) {
	if h.pos[v] >= 0 {
		h.siftUp(int(h.pos[v]))
	}
}

func (h *varHeap) empty() bool { return len(h.heap) == 0 }

func (h *varHeap) pop() int32 {
	top := h.heap[0]
	last := h.heap[len(h.heap)-1]
	h.heap = h.heap[:len(h.heap)-1]
	h.pos[top] = -1
	if len(h.heap) > 0 {
		h.heap[0] = last
		h.pos[last] = 0
		h.siftDown(0)
	}
	return top
}

func (h *varHeap) siftUp(i int) {
	act := *h.act
	x := h.heap[i]
	ax := act[x]
	for i > 0 {
		p := (i - 1) >> 1
		pv := h.heap[p]
		if act[pv] >= ax {
			break
		}
		h.heap[i] = pv
		h.pos[pv] = int32(i)
		i = p
	}
	h.heap[i] = x
	h.pos[x] = int32(i)
}

func (h *varHeap) siftDown(i int) {
	act := *h.act
	n := len(h.heap)
	x := h.heap[i]
	ax := act[x]
	for {
		c := 2*i + 1
		if c >= n {
			break
		}
		if c+1 < n && act[h.heap[c+1]] > act[h.heap[c]] {
			c++
		}
		cv := h.heap[c]
		if act[cv] <= ax {
			break
		}
		h.heap[i] = cv
		h.pos[cv] = int32(i)
		i = c
	}
	h.heap[i] = x
	h.pos[x] = int32(i)
}
