// Package raster contains the pixel side of the renderer: an RGBA canvas of
// float64 channels, group-opacity compositing, a 64-sub-scanline polygon
// filler and the PPM encoder.
package raster

import "math"

// Canvas is a W x H image of interleaved straight-alpha-style RGBA float64
// values (colour channels are stored as produced by source-over compositing,
// i.e. already multiplied by alpha). Everything starts transparent.
type Canvas struct {
	W, H int
	Pix  []float64

	// Rows [lo, hi) are the only ones that may be non-zero.
	lo, hi int
}

// NewCanvas returns a transparent canvas.
func NewCanvas(w, h int) *Canvas {
	return &Canvas{W: w, H: h, Pix: make([]float64, 4*w*h), lo: h}
}

func (c *Canvas) touch(row int) {
	if row < c.lo {
		c.lo = row
	}
	if row+1 > c.hi {
		c.hi = row + 1
	}
}

// Clear makes the canvas transparent again, touching only rows that were
// drawn on.
func (c *Canvas) Clear() {
	if c.lo < c.hi {
		clear(c.Pix[4*c.W*c.lo : 4*c.W*c.hi])
	}
	c.lo, c.hi = c.H, 0
}

// CompositeLayer composites src (same size) onto c with group opacity o:
//
//	dst.rgb = src.rgb*o + dst.rgb*(1 - src.a*o)
//	dst.a   = src.a*o   + dst.a*(1 - src.a*o)
func (c *Canvas) CompositeLayer(src *Canvas, o float64) {
	if src.lo >= src.hi {
		return
	}
	for row := src.lo; row < src.hi; row++ {
		base := 4 * c.W * row
		s := src.Pix[base : base+4*c.W]
		d := c.Pix[base : base+4*c.W]
		for i := 0; i < len(s); i += 4 {
			sa := s[i+3]
			if sa == 0 {
				continue
			}
			ao := sa * o
			k := 1 - ao
			d[i] = s[i]*o + d[i]*k
			d[i+1] = s[i+1]*o + d[i+1]*k
			d[i+2] = s[i+2]*o + d[i+2]*k
			d[i+3] = ao + d[i+3]*k
		}
		c.touch(row)
	}
}

// RGB flattens the canvas over opaque white into W*H*3 bytes.
func (c *Canvas) RGB() []byte {
	out := make([]byte, 3*c.W*c.H)
	for i, j := 0, 0; i < len(c.Pix); i, j = i+4, j+3 {
		w := 1 - c.Pix[i+3]
		for k := 0; k < 3; k++ {
			v := c.Pix[i+k] + w
			out[j+k] = byte(math.Floor(math.Min(1, math.Max(0, v))*255 + 0.5))
		}
	}
	return out
}

// PPM encodes the canvas as a binary P6 image over a white background.
func (c *Canvas) PPM() []byte {
	return EncodePPM(c.W, c.H, c.RGB())
}

// EncodePPM builds a binary P6 file from w*h*3 RGB bytes.
func EncodePPM(w, h int, rgb []byte) []byte {
	hdr := []byte("P6\n" + itoa(w) + " " + itoa(h) + "\n255\n")
	out := make([]byte, 0, len(hdr)+len(rgb))
	out = append(out, hdr...)
	return append(out, rgb...)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for ; n > 0; n /= 10 {
		i--
		b[i] = byte('0' + n%10)
	}
	return string(b[i:])
}
