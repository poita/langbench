package qrcode

// NumMasks is the number of mask patterns.
const NumMasks = 8

// maskCondition reports whether mask pattern m inverts module (x, y).
func maskCondition(m, x, y int) bool {
	switch m {
	case 0:
		return (x+y)%2 == 0
	case 1:
		return y%2 == 0
	case 2:
		return x%3 == 0
	case 3:
		return (x+y)%3 == 0
	case 4:
		return (x/3+y/2)%2 == 0
	case 5:
		return x*y%2+x*y%3 == 0
	case 6:
		return (x*y%2+x*y%3)%2 == 0
	default:
		return ((x+y)%2+x*y%3)%2 == 0
	}
}

// applyMask inverts every non-function module selected by mask m.
func (g *grid) applyMask(m int) {
	for y := 0; y < g.n; y++ {
		for x := 0; x < g.n; x++ {
			i := y*g.n + x
			if !g.function[i] && maskCondition(m, x, y) {
				g.modules[i] = !g.modules[i]
			}
		}
	}
}

// Window patterns of the N3 penalty, as 11-bit values (first module is the
// most significant bit, dark = 1): #.###.#.... and ....#.###.#
const (
	finderLikeA = 0b10111010000
	finderLikeB = 0b00001011101
)

// penalty computes the total mask penalty score (N1+N2+N3+N4) of the complete
// symbol.
func (g *grid) penalty() int {
	n := g.n
	score := 0
	line := make([]bool, n)
	for pass := 0; pass < 2; pass++ {
		for a := 0; a < n; a++ {
			for b := 0; b < n; b++ {
				if pass == 0 {
					line[b] = g.modules[a*n+b] // row a
				} else {
					line[b] = g.modules[b*n+a] // column a
				}
			}
			score += linePenalty(line)
		}
	}

	// N2: 2x2 blocks of one colour.
	for y := 0; y+1 < n; y++ {
		for x := 0; x+1 < n; x++ {
			c := g.modules[y*n+x]
			if c == g.modules[y*n+x+1] && c == g.modules[(y+1)*n+x] && c == g.modules[(y+1)*n+x+1] {
				score += 3
			}
		}
	}

	score += g.balancePenalty()
	return score
}

// linePenalty returns N1 + N3 for one row or column.
func linePenalty(line []bool) int {
	score := 0
	// N1: runs of 5 or more.
	run := 1
	for i := 1; i <= len(line); i++ {
		if i < len(line) && line[i] == line[i-1] {
			run++
			continue
		}
		if run >= 5 {
			score += 3 + run - 5
		}
		run = 1
	}
	// N3: finder-like windows lying fully inside the line.
	window := 0
	for i, d := range line {
		window <<= 1
		if d {
			window |= 1
		}
		window &= 0x7FF
		if i >= 10 {
			if window == finderLikeA {
				score += 40
			}
			if window == finderLikeB {
				score += 40
			}
		}
	}
	return score
}

// balancePenalty returns N4: 10*k where k is the number of complete 5% steps
// by which the dark proportion deviates from 50%.
func (g *grid) balancePenalty() int {
	dark := 0
	for _, m := range g.modules {
		if m {
			dark++
		}
	}
	total := g.n * g.n
	dev := 20*dark - 10*total
	if dev < 0 {
		dev = -dev
	}
	return 10 * (dev / total)
}
