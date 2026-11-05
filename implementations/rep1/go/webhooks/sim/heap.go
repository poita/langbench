package sim

// item is a pending attempt: when it is due and which delivery it belongs to.
type item struct {
	time     int64
	delivery int32
}

func (a item) less(b item) bool {
	return a.time < b.time || a.time == b.time && a.delivery < b.delivery
}

// heap is a binary min-heap over reserved storage; push and pop work in place.
type heap struct {
	a []item
}

// newHeap heapifies items in O(n).
func newHeap(items []item, capacity int) *heap {
	a := make([]item, len(items), max(capacity, len(items)))
	copy(a, items)
	h := &heap{a: a}
	for i := len(a)/2 - 1; i >= 0; i-- {
		h.down(i)
	}
	return h
}

func (h *heap) len() int { return len(h.a) }

func (h *heap) push(x item) {
	h.a = append(h.a, x)
	i := len(h.a) - 1
	for i > 0 {
		p := (i - 1) / 2
		if !h.a[i].less(h.a[p]) {
			break
		}
		h.a[i], h.a[p] = h.a[p], h.a[i]
		i = p
	}
}

func (h *heap) pop() item {
	top := h.a[0]
	last := len(h.a) - 1
	h.a[0] = h.a[last]
	h.a = h.a[:last]
	if last > 0 {
		h.down(0)
	}
	return top
}

func (h *heap) down(i int) {
	n := len(h.a)
	for {
		l := 2*i + 1
		if l >= n {
			return
		}
		m := l
		if r := l + 1; r < n && h.a[r].less(h.a[l]) {
			m = r
		}
		if !h.a[m].less(h.a[i]) {
			return
		}
		h.a[i], h.a[m] = h.a[m], h.a[i]
		i = m
	}
}
