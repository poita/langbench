package chip8

import "strings"

// Display dimensions in pixels.
const (
	Width  = 64
	Height = 32
)

// Display is a 64x32 monochrome frame buffer. The zero value is a blank
// display.
type Display struct {
	pix [Height][Width]bool
}

// Clear turns every pixel off.
func (d *Display) Clear() { d.pix = [Height][Width]bool{} }

// Pixel reports whether the pixel at column x, row y is lit. Coordinates
// outside the display report false.
func (d *Display) Pixel(x, y int) bool {
	if x < 0 || x >= Width || y < 0 || y >= Height {
		return false
	}
	return d.pix[y][x]
}

// xor toggles the pixel at (x, y), wrapping coordinates, and reports whether
// it was lit before (that is, whether the toggle turned a pixel off).
func (d *Display) xor(x, y int) bool {
	p := &d.pix[y&(Height-1)][x&(Width-1)]
	was := *p
	*p = !was
	return was
}

// DrawSprite XORs the sprite rows onto the display with its origin at
// (x, y), reduced modulo the display size. Each byte is one row of eight
// pixels, most significant bit leftmost. Pixels past an edge wrap around. It
// reports whether any lit pixel was turned off.
func (d *Display) DrawSprite(x, y int, rows []byte) (collision bool) {
	sx, sy := x&(Width-1), y&(Height-1)
	for r, b := range rows {
		for bit := 0; bit < 8; bit++ {
			if b>>(7-bit)&1 != 0 && d.xor(sx+bit, sy+r) {
				collision = true
			}
		}
	}
	return collision
}

// String renders the display as 32 lines of 64 characters, '#' for a lit
// pixel and '.' for an unlit one, each line terminated by a newline.
func (d *Display) String() string {
	var sb strings.Builder
	sb.Grow(Height * (Width + 1))
	for y := range d.pix {
		for x := range d.pix[y] {
			if d.pix[y][x] {
				sb.WriteByte('#')
			} else {
				sb.WriteByte('.')
			}
		}
		sb.WriteByte('\n')
	}
	return sb.String()
}
