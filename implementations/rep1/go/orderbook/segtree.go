package orderbook

// segTree is an array-backed segment tree over the price levels of one side.
// Each node stores the sum of the quantities below it and the number of
// non-empty levels below it. The root is node 1; the leaves are nodes
// n..2n-1 where n is a power of two at least as large as the level count.
type segTree struct {
	n   int
	sum []int64
	cnt []int32
}

func newSegTree(levels int) segTree {
	n := 1
	for n < levels {
		n <<= 1
	}
	return segTree{n: n, sum: make([]int64, 2*n), cnt: make([]int32, 2*n)}
}

// set stores the state of leaf i and refreshes the path above it. nonEmpty
// states whether the level has any orders.
func (t *segTree) set(i int, sum int64, nonEmpty bool) {
	i += t.n
	t.sum[i] = sum
	if nonEmpty {
		t.cnt[i] = 1
	} else {
		t.cnt[i] = 0
	}
	for i > 1 {
		i >>= 1
		t.sum[i] = t.sum[2*i] + t.sum[2*i+1]
		t.cnt[i] = t.cnt[2*i] + t.cnt[2*i+1]
	}
}

// lowest returns the lowest non-empty leaf, or -1 if there is none.
func (t *segTree) lowest() int {
	if t.cnt[1] == 0 {
		return -1
	}
	return t.descendLow(1)
}

// highest returns the highest non-empty leaf, or -1 if there is none.
func (t *segTree) highest() int {
	if t.cnt[1] == 0 {
		return -1
	}
	return t.descendHigh(1)
}

// descendLow returns the lowest non-empty leaf below non-empty node j.
func (t *segTree) descendLow(j int) int {
	for j < t.n {
		j <<= 1
		if t.cnt[j] == 0 {
			j++
		}
	}
	return j - t.n
}

// descendHigh returns the highest non-empty leaf below non-empty node j.
func (t *segTree) descendHigh(j int) int {
	for j < t.n {
		j = j<<1 + 1
		if t.cnt[j] == 0 {
			j--
		}
	}
	return j - t.n
}

// next returns the lowest non-empty leaf >= i, or -1.
func (t *segTree) next(i int) int {
	if i < 0 {
		i = 0
	}
	if i >= t.n {
		return -1
	}
	j := i + t.n
	if t.cnt[j] > 0 {
		return i
	}
	for j > 1 {
		if j&1 == 0 && t.cnt[j+1] > 0 {
			return t.descendLow(j + 1)
		}
		j >>= 1
	}
	return -1
}

// prev returns the highest non-empty leaf <= i, or -1.
func (t *segTree) prev(i int) int {
	if i >= t.n {
		i = t.n - 1
	}
	if i < 0 {
		return -1
	}
	j := i + t.n
	if t.cnt[j] > 0 {
		return i
	}
	for j > 1 {
		if j&1 == 1 && t.cnt[j-1] > 0 {
			return t.descendHigh(j - 1)
		}
		j >>= 1
	}
	return -1
}

// rangeSum returns the sum over leaves in the half-open range [lo, hi).
func (t *segTree) rangeSum(lo, hi int) int64 {
	if lo < 0 {
		lo = 0
	}
	if hi > t.n {
		hi = t.n
	}
	var s int64
	for l, r := lo+t.n, hi+t.n; l < r; l, r = l>>1, r>>1 {
		if l&1 == 1 {
			s += t.sum[l]
			l++
		}
		if r&1 == 1 {
			r--
			s += t.sum[r]
		}
	}
	return s
}

// prefixSum returns the sum over leaves 0..i inclusive.
func (t *segTree) prefixSum(i int) int64 { return t.rangeSum(0, i+1) }

// suffixSum returns the sum over leaves i..n-1.
func (t *segTree) suffixSum(i int) int64 { return t.rangeSum(i, t.n) }
