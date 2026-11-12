package sat

// luby returns the i-th (0-based) element of the Luby restart sequence with
// base y: 1 1 2 1 1 2 4 1 1 2 1 1 2 4 8 ... (for y = 2), where each value is
// y raised to the returned exponent.
func luby(y float64, i int) float64 {
	// Find the finite subsequence that contains index i, and the size of it.
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
	r := 1.0
	for ; seq > 0; seq-- {
		r *= y
	}
	return r
}
