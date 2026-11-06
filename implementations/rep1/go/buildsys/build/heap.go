package build

// minHeap is a binary min-heap of ints.
type minHeap []int

func (h *minHeap) push(x int) {
	*h = append(*h, x)
	a := *h
	i := len(a) - 1
	for i > 0 {
		p := (i - 1) / 2
		if a[p] <= a[i] {
			break
		}
		a[p], a[i] = a[i], a[p]
		i = p
	}
}

func (h *minHeap) pop() int {
	a := *h
	top := a[0]
	n := len(a) - 1
	a[0] = a[n]
	a = a[:n]
	*h = a
	i := 0
	for {
		l, r, m := 2*i+1, 2*i+2, i
		if l < n && a[l] < a[m] {
			m = l
		}
		if r < n && a[r] < a[m] {
			m = r
		}
		if m == i {
			break
		}
		a[i], a[m] = a[m], a[i]
		i = m
	}
	return top
}

func (h minHeap) len() int { return len(h) }
