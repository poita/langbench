package sat

// luby returns the i-th (0-based) element of the Luby restart sequence
// 1 1 2 1 1 2 4 1 1 2 1 1 2 4 8 ... scaled by base: base^k for the
// appropriate k.
func luby(base, i int) int {
	size, seq := 1, 0
	for size < i+1 {
		seq++
		size = 2*size + 1
	}
	for size-1 != i {
		size = (size - 1) >> 1
		seq--
		i %= size
	}
	r := 1
	for ; seq > 0; seq-- {
		r *= base
	}
	return r
}
