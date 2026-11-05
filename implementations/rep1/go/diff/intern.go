package linediff

// Intern maps every distinct line of a and b to a dense int32 id (0, 1, 2,
// ... in order of first appearance, a before b) and returns the two id
// sequences together with the number of distinct lines. Equal lines get equal
// ids, so later comparisons are single integer comparisons.
func Intern(a, b [][]byte) (ia, ib []int32, distinct int) {
	ids := make(map[string]int32, len(a)+len(b))
	conv := func(lines [][]byte) []int32 {
		out := make([]int32, len(lines))
		for i, l := range lines {
			// The m[string(bytes)] lookup form does not allocate.
			id, ok := ids[string(l)]
			if !ok {
				id = int32(len(ids))
				ids[string(l)] = id // allocates only for a new key
			}
			out[i] = id
		}
		return out
	}
	ia = conv(a)
	ib = conv(b)
	return ia, ib, len(ids)
}
