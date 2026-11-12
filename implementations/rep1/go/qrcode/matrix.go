package qrcode

// grid is a square module matrix together with a mask of function modules.
type grid struct {
	n        int
	modules  []bool // true = dark; index y*n + x
	function []bool // true = function module (never masked, holds no data)
}

func newGrid(version int) *grid {
	n := Size(version)
	return &grid{n: n, modules: make([]bool, n*n), function: make([]bool, n*n)}
}

func (g *grid) clone() *grid {
	c := &grid{n: g.n, modules: make([]bool, len(g.modules)), function: g.function}
	copy(c.modules, g.modules)
	return c
}

// setFunction sets module (x, y) and marks it as a function module.
func (g *grid) setFunction(x, y int, dark bool) {
	g.modules[y*g.n+x] = dark
	g.function[y*g.n+x] = true
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

// newFunctionGrid returns a grid for version holding all function patterns
// (finders, timing, alignment, dark module, version information) and with the
// format-information area reserved. Format modules are drawn with mask 0 and
// level L; call drawFormat to set the real values.
func newFunctionGrid(version int) *grid {
	g := newGrid(version)
	n := g.n

	// Timing patterns first; finders and alignment patterns overwrite them.
	for i := 0; i < n; i++ {
		g.setFunction(i, 6, i%2 == 0)
		g.setFunction(6, i, i%2 == 0)
	}

	// Finder patterns with separators.
	for _, c := range [][2]int{{3, 3}, {n - 4, 3}, {3, n - 4}} {
		for dy := -4; dy <= 4; dy++ {
			for dx := -4; dx <= 4; dx++ {
				x, y := c[0]+dx, c[1]+dy
				if x < 0 || y < 0 || x >= n || y >= n {
					continue
				}
				d := max(abs(dx), abs(dy))
				g.setFunction(x, y, d != 2 && d != 4)
			}
		}
	}

	// Alignment patterns.
	pos := alignmentCoords[version-1]
	for i, py := range pos {
		for j, px := range pos {
			last := len(pos) - 1
			if (i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0) {
				continue
			}
			for dy := -2; dy <= 2; dy++ {
				for dx := -2; dx <= 2; dx++ {
					d := max(abs(dx), abs(dy))
					g.setFunction(px+dx, py+dy, d != 1)
				}
			}
		}
	}

	g.drawFormat(L, 0)
	g.setFunction(8, n-8, true) // dark module
	g.drawVersion(version)
	return g
}

// bchRemainder computes the remainder of data*x^degreeBits modulo poly, where
// poly has degree degreeBits.
func bchRemainder(data uint32, poly uint32, degreeBits uint) uint32 {
	rem := data
	for i := uint(0); i < degreeBits; i++ {
		rem = rem<<1 ^ (rem>>(degreeBits-1))*poly
	}
	return rem
}

// drawVersion writes the 18-bit version information (versions >= 7).
func (g *grid) drawVersion(version int) {
	if version < 7 {
		return
	}
	// rem is 12 bits; the update rule of the standard uses a 12-bit register.
	rem := uint32(version)
	for i := 0; i < 12; i++ {
		rem = rem<<1 ^ (rem>>11)*0x1F25
	}
	bits := uint32(version)<<12 | rem
	n := g.n
	for i := 0; i < 18; i++ {
		dark := bits>>uint(i)&1 == 1
		a, b := n-11+i%3, i/3
		g.setFunction(a, b, dark)
		g.setFunction(b, a, dark)
	}
}

// formatBitsFor returns the 15-bit masked format information.
func formatBitsFor(level Level, mask int) uint32 {
	data := uint32(formatBits[level])<<3 | uint32(mask)
	rem := bchRemainder(data, 0x537, 10)
	return (data<<10 | rem) ^ 0x5412
}

// drawFormat writes both copies of the format information.
func (g *grid) drawFormat(level Level, mask int) {
	bits := formatBitsFor(level, mask)
	bit := func(i int) bool { return bits>>uint(i)&1 == 1 }
	n := g.n
	for i := 0; i <= 5; i++ {
		g.setFunction(8, i, bit(i))
	}
	g.setFunction(8, 7, bit(6))
	g.setFunction(8, 8, bit(7))
	g.setFunction(7, 8, bit(8))
	for i := 9; i <= 14; i++ {
		g.setFunction(14-i, 8, bit(i))
	}
	for i := 0; i <= 7; i++ {
		g.setFunction(n-1-i, 8, bit(i))
	}
	for i := 8; i <= 14; i++ {
		g.setFunction(8, n-15+i, bit(i))
	}
}

// placeData writes the codeword bits along the zigzag path into the
// non-function modules. Modules left over stay light.
func (g *grid) placeData(codewords []byte) {
	n := g.n
	bitIdx := 0
	total := len(codewords) * 8
	for r := n - 1; r >= 1; r -= 2 {
		if r == 6 {
			r = 5 // column 6 is the timing column and holds no data
		}
		up := (r+1)&2 == 0
		for k := 0; k < n; k++ {
			y := k
			if up {
				y = n - 1 - k
			}
			for _, x := range [2]int{r, r - 1} {
				if g.function[y*n+x] || bitIdx >= total {
					continue
				}
				g.modules[y*n+x] = codewords[bitIdx>>3]>>(7-uint(bitIdx&7))&1 == 1
				bitIdx++
			}
		}
	}
}
