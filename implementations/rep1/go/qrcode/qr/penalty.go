package qr

// penalty computes the total N1+N2+N3+N4 penalty score of a complete symbol.
func penalty(g *grid) int {
	n := g.n
	m := g.mod
	score := 0
	dark := 0
	for _, c := range m {
		dark += int(c)
	}
	// N1 and N3: one fused scan per row and per column.
	for i := 0; i < n; i++ {
		score += scanLine(m, i*n, 1, n)
		score += scanLine(m, i, n, n)
	}
	// N2: 2x2 blocks of one colour.
	for y := 0; y+1 < n; y++ {
		r0 := m[y*n : y*n+n]
		r1 := m[(y+1)*n : (y+1)*n+n]
		for x := 0; x+1 < n; x++ {
			c := r0[x]
			if c == r0[x+1] && c == r1[x] && c == r1[x+1] {
				score += 3
			}
		}
	}
	// N4: deviation from 50% dark in 5% steps.
	total := n * n
	d := 20*dark - 10*total
	if d < 0 {
		d = -d
	}
	score += 10 * (d / total)
	return score
}

// scanLine scores runs (N1) and finder-like patterns (N3) along one line of
// n modules starting at index start with the given stride.
func scanLine(m []byte, start, step, n int) int {
	score := 0
	runColor := m[start]
	runLen := 1
	window := uint32(runColor)
	idx := start + step
	for k := 1; k < n; k++ {
		c := m[idx]
		idx += step
		if c == runColor {
			runLen++
		} else {
			if runLen >= 5 {
				score += runLen - 2
			}
			runColor = c
			runLen = 1
		}
		window = (window<<1 | uint32(c)) & 0x7FF
		if k >= 10 && (window == 0x5D0 || window == 0x05D) {
			score += 40
		}
	}
	if runLen >= 5 {
		score += runLen - 2
	}
	return score
}
