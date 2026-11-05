package chip8

import "math/bits"

// Display dimensions in pixels.
const (
	Width  = 64
	Height = 32
)

// Display is the 64x32 monochrome screen. Each row is one 64-bit word in which
// column 0 is the most significant bit.
type Display [Height]uint64

// Clear turns every pixel off.
func (d *Display) Clear() { *d = Display{} }

// Pixel reports whether the pixel at column x, row y is lit. Coordinates wrap.
func (d *Display) Pixel(x, y int) bool {
	return d[y&(Height-1)]>>(63-uint(x&(Width-1)))&1 != 0
}

// SetPixel turns the pixel at column x, row y on or off. Coordinates wrap.
func (d *Display) SetPixel(x, y int, on bool) {
	m := uint64(1) << (63 - uint(x&(Width-1)))
	if on {
		d[y&(Height-1)] |= m
	} else {
		d[y&(Height-1)] &^= m
	}
}

// XORRow XORs the eight bits of b into row y starting at column x, wrapping
// horizontally, and reports whether any lit pixel was turned off.
func (d *Display) XORRow(x, y int, b byte) (collision bool) {
	row := bits.RotateLeft64(uint64(b)<<56, -(x & (Width - 1))) // rotate right by x
	r := &d[y&(Height-1)]
	collision = *r&row != 0
	*r ^= row
	return collision
}
