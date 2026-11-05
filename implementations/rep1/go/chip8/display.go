package chip8

// Display geometry.
const (
	Width  = 64
	Height = 32
)

// Display is the 64x32 monochrome screen. Each row is one 64-bit word in
// which column 0 is the most significant bit and column 63 the least.
type Display [Height]uint64

// Clear turns every pixel off.
func (d *Display) Clear() { *d = Display{} }

// Pixel reports whether the pixel at column x, row y is lit. Coordinates are
// reduced modulo the screen size.
func (d *Display) Pixel(x, y int) bool {
	return d[y&(Height-1)]>>(63-uint(x&(Width-1)))&1 != 0
}

// Set turns the pixel at column x, row y on or off.
func (d *Display) Set(x, y int, on bool) {
	bit := uint64(1) << (63 - uint(x&(Width-1)))
	if on {
		d[y&(Height-1)] |= bit
	} else {
		d[y&(Height-1)] &^= bit
	}
}

// Lit returns the number of lit pixels.
func (d *Display) Lit() int {
	n := 0
	for _, r := range d {
		for ; r != 0; r &= r - 1 {
			n++
		}
	}
	return n
}

// AppendRows appends the display as 32 lines of 64 '#'/'.' characters, each
// terminated by a newline, and returns the extended buffer.
func (d *Display) AppendRows(dst []byte) []byte {
	for _, r := range d {
		for x := 63; x >= 0; x-- {
			if r>>uint(x)&1 != 0 {
				dst = append(dst, '#')
			} else {
				dst = append(dst, '.')
			}
		}
		dst = append(dst, '\n')
	}
	return dst
}
