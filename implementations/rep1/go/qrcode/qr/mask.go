package qr

// maskApplies reports whether mask pattern m inverts module (x, y).
func maskApplies(m, x, y int) bool {
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
		return (x*y)%2+(x*y)%3 == 0
	case 6:
		return ((x*y)%2+(x*y)%3)%2 == 0
	default:
		return ((x+y)%2+(x*y)%3)%2 == 0
	}
}

// render copies b into dst, applies mask m to non-function modules and
// writes the format information.
func (b *base) render(dst *grid, ecl ECL, m int) {
	copy(dst.mod, b.mod)
	n := b.n
	for y := 0; y < n; y++ {
		row := y * n
		for x := 0; x < n; x++ {
			if b.fn[row+x] == 0 && maskApplies(m, x, y) {
				dst.mod[row+x] ^= 1
			}
		}
	}
	writeFormat(dst, ecl, m)
}
