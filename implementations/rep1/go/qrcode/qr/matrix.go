package qr

// grid is a square module matrix, one byte per module (1 = dark), row-major.
type grid struct {
	n   int
	mod []byte
}

func newGrid(n int) grid { return grid{n: n, mod: make([]byte, n*n)} }

// base holds the unmasked symbol and the function-module map.
type base struct {
	grid
	fn []byte // 1 where the module is a function module
}

func (b *base) setFn(x, y int, dark bool) {
	i := y*b.n + x
	b.fn[i] = 1
	if dark {
		b.mod[i] = 1
	} else {
		b.mod[i] = 0
	}
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

// newBase builds the function patterns of version v and places the codewords.
// The format area is reserved (marked as function, light) but not filled.
func newBase(v int, codewords []byte) *base {
	n := Size(v)
	b := &base{grid: newGrid(n), fn: make([]byte, n*n)}

	// Finder patterns with separators.
	for _, c := range [3][2]int{{3, 3}, {n - 4, 3}, {3, n - 4}} {
		for dy := -4; dy <= 4; dy++ {
			for dx := -4; dx <= 4; dx++ {
				x, y := c[0]+dx, c[1]+dy
				if x < 0 || y < 0 || x >= n || y >= n {
					continue
				}
				d := max(abs(dx), abs(dy))
				b.setFn(x, y, d != 2 && d != 4)
			}
		}
	}
	// Timing patterns.
	for i := 8; i <= n-9; i++ {
		b.setFn(i, 6, i%2 == 0)
		b.setFn(6, i, i%2 == 0)
	}
	// Alignment patterns.
	pos := alignPos[v-1]
	for i, py := range pos {
		for j, px := range pos {
			last := len(pos) - 1
			if (i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0) {
				continue
			}
			for dy := -2; dy <= 2; dy++ {
				for dx := -2; dx <= 2; dx++ {
					d := max(abs(dx), abs(dy))
					b.setFn(px+dx, py+dy, d != 1)
				}
			}
		}
	}
	// Reserve format areas (values written per mask) and the dark module.
	for i := 0; i < 9; i++ {
		if i != 6 { // (8,6) and (6,8) belong to the timing patterns
			b.setFn(8, i, false)
			b.setFn(i, 8, false)
		}
	}
	for i := 0; i < 8; i++ {
		b.setFn(n-1-i, 8, false)
	}
	for i := 8; i < 15; i++ {
		b.setFn(8, n-15+i, false)
	}
	b.setFn(8, n-8, true)
	// Version information.
	if v >= 7 {
		bits := versionBits(v)
		for i := 0; i < 18; i++ {
			dark := bits>>uint(i)&1 != 0
			a, c := n-11+i%3, i/3
			b.setFn(a, c, dark)
			b.setFn(c, a, dark)
		}
	}

	b.placeCodewords(codewords)
	return b
}

// placeCodewords walks the zigzag and stores codeword bits in free modules.
func (b *base) placeCodewords(cw []byte) {
	n := b.n
	bit := 0
	nbits := len(cw) * 8
	for right := n - 1; right >= 1; right -= 2 {
		if right == 6 {
			right = 5
		}
		up := (right+1)&2 == 0
		for k := 0; k < n; k++ {
			y := k
			if up {
				y = n - 1 - k
			}
			for dx := 0; dx < 2; dx++ {
				i := y*n + right - dx
				if b.fn[i] == 0 && bit < nbits {
					b.mod[i] = cw[bit>>3] >> uint(7-bit&7) & 1
					bit++
				}
			}
		}
	}
}

func versionBits(v int) uint32 {
	rem := uint32(v)
	for i := 0; i < 12; i++ {
		rem = rem<<1 ^ (rem>>11)*0x1F25
	}
	return uint32(v)<<12 | rem
}

func formatInfoBits(ecl ECL, mask int) uint32 {
	data := uint32(formatBits[ecl]<<3 | mask)
	rem := data
	for i := 0; i < 10; i++ {
		rem = rem<<1 ^ (rem>>9)*0x537
	}
	return (data<<10 | rem) ^ 0x5412
}

// writeFormat stores both copies of the format information in g.
func writeFormat(g *grid, ecl ECL, mask int) {
	n := g.n
	bits := formatInfoBits(ecl, mask)
	set := func(x, y int, i int) { g.mod[y*n+x] = byte(bits >> uint(i) & 1) }
	for i := 0; i <= 5; i++ {
		set(8, i, i)
	}
	set(8, 7, 6)
	set(8, 8, 7)
	set(7, 8, 8)
	for i := 9; i <= 14; i++ {
		set(14-i, 8, i)
	}
	for i := 0; i <= 7; i++ {
		set(n-1-i, 8, i)
	}
	for i := 8; i <= 14; i++ {
		set(8, n-15+i, i)
	}
}
