package chip8

const (
	// Width is the display width in pixels.
	Width = 64
	// Height is the display height in pixels.
	Height = 32
)

// Display is a 64x32 monochrome frame buffer. Pixels are indexed [row][column].
type Display [Height][Width]bool

// Clear turns every pixel off.
func (d *Display) Clear() { *d = Display{} }

// Pixel reports whether the pixel at column x, row y is lit.
func (d *Display) Pixel(x, y int) bool { return d[y][x] }

// drawSprite XORs sprite rows (one byte per row, most significant bit leftmost)
// onto the display with origin (x, y), wrapping around the edges. It reports
// whether any lit pixel was turned off.
func (d *Display) drawSprite(x, y int, rows []byte) (collision bool) {
	for r, b := range rows {
		py := (y + r) & (Height - 1)
		for bit := 0; bit < 8; bit++ {
			if b&(0x80>>bit) == 0 {
				continue
			}
			px := (x + bit) & (Width - 1)
			if d[py][px] {
				collision = true
			}
			d[py][px] = !d[py][px]
		}
	}
	return collision
}

// String renders the display as 32 newline-terminated lines of 64 characters,
// using '#' for lit pixels and '.' for unlit ones.
func (d *Display) String() string {
	buf := make([]byte, 0, Height*(Width+1))
	for y := 0; y < Height; y++ {
		for x := 0; x < Width; x++ {
			if d[y][x] {
				buf = append(buf, '#')
			} else {
				buf = append(buf, '.')
			}
		}
		buf = append(buf, '\n')
	}
	return string(buf)
}
