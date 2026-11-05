package chip8

import "math/bits"

// Display dimensions in pixels.
const (
	Width  = 64
	Height = 32
)

// Display is a 64x32 monochrome frame buffer. Each row is one 64-bit word;
// column 0 is the most significant bit.
type Display [Height]uint64

// Clear turns every pixel off.
func (d *Display) Clear() { *d = Display{} }

// Pixel reports whether the pixel at column x, row y is lit.
// Coordinates outside the display are reduced modulo its size.
func (d *Display) Pixel(x, y int) bool {
	return d[y&(Height-1)]>>(63-uint(x&(Width-1)))&1 != 0
}

// SetPixel turns the pixel at column x, row y on or off.
func (d *Display) SetPixel(x, y int, on bool) {
	bit := uint64(1) << (63 - uint(x&(Width-1)))
	if on {
		d[y&(Height-1)] |= bit
	} else {
		d[y&(Height-1)] &^= bit
	}
}

// XORRow XORs the 8 bits of b into row y at columns sx..sx+7, wrapping
// around the right edge, and reports whether any lit pixel was turned off.
func (d *Display) XORRow(y int, sx uint, b byte) (collision bool) {
	row := bits.RotateLeft64(uint64(b)<<56, -int(sx&63))
	r := &d[y&(Height-1)]
	collision = *r&row != 0
	*r ^= row
	return collision
}
