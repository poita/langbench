package sched

// minHeap is a binary min-heap of non-negative ints (step serial numbers).
type minHeap struct{ a []int }

func (h *minHeap) len() int { return len(h.a) }

func (h *minHeap) push(x int) {
	h.a = append(h.a, x)
	i := len(h.a) - 1
	for i > 0 {
		p := (i - 1) / 2
		if h.a[p] <= h.a[i] {
			break
		}
		h.a[p], h.a[i] = h.a[i], h.a[p]
		i = p
	}
}

func (h *minHeap) pop() int {
	top := h.a[0]
	last := len(h.a) - 1
	h.a[0] = h.a[last]
	h.a = h.a[:last]
	i := 0
	for {
		l, r, m := 2*i+1, 2*i+2, i
		if l < last && h.a[l] < h.a[m] {
			m = l
		}
		if r < last && h.a[r] < h.a[m] {
			m = r
		}
		if m == i {
			break
		}
		h.a[m], h.a[i] = h.a[i], h.a[m]
		i = m
	}
	return top
}
