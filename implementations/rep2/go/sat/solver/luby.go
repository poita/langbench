package solver

// luby returns the i-th (0-based) element of the Luby sequence
// 1 1 2 1 1 2 4 1 1 2 1 1 2 4 8 ... scaled to base 2.
func luby(i int) int {
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
	return 1 << seq
}
