package raster

import (
	"bufio"
	"fmt"
	"io"
	"math"

	"svgraster/geom"
)

// Canvas is a W x H RGBA surface of float64 channels. Colour channels are
// stored already multiplied by alpha, matching the compositing recurrences of
// the specification. A new canvas is fully transparent.
type Canvas struct {
	W, H int
	Pix  []float64 // 4 values (r, g, b, a) per pixel, row-major

	rast    *Rasterizer
	dirtyLo int // first row possibly touched
	dirtyHi int // one past the last row possibly touched
}

// NewCanvas returns a transparent canvas.
func NewCanvas(w, h int) *Canvas {
	return &Canvas{W: w, H: h, Pix: make([]float64, w*h*4), dirtyLo: h, dirtyHi: 0}
}

func (c *Canvas) touch(y int) {
	if y < c.dirtyLo {
		c.dirtyLo = y
	}
	if y >= c.dirtyHi {
		c.dirtyHi = y + 1
	}
}

// Clear makes the canvas transparent again, touching only rows that have been
// drawn on.
func (c *Canvas) Clear() {
	for y := c.dirtyLo; y < c.dirtyHi; y++ {
		row := c.Pix[y*c.W*4 : (y+1)*c.W*4]
		for i := range row {
			row[i] = 0
		}
	}
	c.dirtyLo, c.dirtyHi = c.H, 0
}

// FillPolygons fills the polygons (device space, implicitly closed) with the
// colour rgb (each channel 0..1) at the given paint opacity, source-over.
func (c *Canvas) FillPolygons(polys [][]geom.Point, rule FillRule, rgb [3]float64, opacity float64) {
	if c.rast == nil {
		c.rast = NewRasterizer(c.W, c.H)
	}
	c.rast.Fill(polys, rule, func(y, x0 int, cov []float64) {
		c.touch(y)
		px := c.Pix[(y*c.W+x0)*4:]
		for i, cv := range cov {
			if cv <= 0 {
				continue
			}
			a := opacity * cv
			q := px[i*4 : i*4+4 : i*4+4]
			q[0] = rgb[0]*a + q[0]*(1-a)
			q[1] = rgb[1]*a + q[1]*(1-a)
			q[2] = rgb[2]*a + q[2]*(1-a)
			q[3] = a + q[3]*(1-a)
		}
	})
}

// DrawLayer composites src (same size) onto c with group opacity o:
// dst = src*o + dst*(1 - src.a*o).
func (c *Canvas) DrawLayer(src *Canvas, o float64) {
	for y := src.dirtyLo; y < src.dirtyHi; y++ {
		c.touch(y)
		s := src.Pix[y*c.W*4 : (y+1)*c.W*4]
		d := c.Pix[y*c.W*4 : (y+1)*c.W*4]
		for i := 0; i < len(s); i += 4 {
			sa := s[i+3]
			if sa == 0 {
				continue
			}
			k := 1 - sa*o
			d[i] = s[i]*o + d[i]*k
			d[i+1] = s[i+1]*o + d[i+1]*k
			d[i+2] = s[i+2]*o + d[i+2]*k
			d[i+3] = sa*o + d[i+3]*k
		}
	}
}

// Image is an opaque 8-bit RGB image.
type Image struct {
	W, H int
	Pix  []byte // 3 bytes per pixel, row-major
}

// ToImage composites the canvas over opaque white and quantises it to 8 bits.
func (c *Canvas) ToImage() *Image {
	img := &Image{W: c.W, H: c.H, Pix: make([]byte, c.W*c.H*3)}
	for i, j := 0, 0; i < len(c.Pix); i, j = i+4, j+3 {
		inv := 1 - c.Pix[i+3]
		for k := 0; k < 3; k++ {
			v := c.Pix[i+k] + inv
			img.Pix[j+k] = byte(math.Floor(math.Min(1, math.Max(0, v))*255 + 0.5))
		}
	}
	return img
}

// WritePPM writes the image as a binary PPM (P6) file.
func (img *Image) WritePPM(w io.Writer) error {
	bw := bufio.NewWriter(w)
	if _, err := fmt.Fprintf(bw, "P6\n%d %d\n255\n", img.W, img.H); err != nil {
		return err
	}
	if _, err := bw.Write(img.Pix); err != nil {
		return err
	}
	return bw.Flush()
}
