// Package svgraster renders a subset of SVG 1.1 to bitmap images.
//
// It is a from-scratch rasteriser using only the Go standard library: a small
// XML reader, path and shape handling, stroke outlining, an anti-aliasing
// active-edge scanline filler and alpha compositing. The supported subset is
// described in the README.
//
// The simplest use is Render, which turns SVG source into an image:
//
//	img, err := svgraster.Render(svgBytes, 128, 128)
//	if err != nil { ... }
//	err = img.WritePPM(w)
//
// The building blocks live in sub-packages: xmlmini (XML), svgparse (values),
// path (path data and flattening), stroke (outlines), raster (scan
// conversion and compositing) and render (the tree walk).
package svgraster

import (
	"fmt"

	"svgraster/raster"
	"svgraster/render"
	"svgraster/xmlmini"
)

// MaxSize is the largest image dimension Render accepts.
const MaxSize = 4096

// Image is an opaque 8-bit RGB image; see raster.Image.
type Image = raster.Image

// Render rasterises the SVG document in src into a width x height image,
// composited over an opaque white background. The document's view box is
// stretched to fill the image.
func Render(src []byte, width, height int) (*Image, error) {
	if width < 1 || height < 1 || width > MaxSize || height > MaxSize {
		return nil, fmt.Errorf("svgraster: invalid size %dx%d (each side must be 1..%d)", width, height, MaxSize)
	}
	root, err := xmlmini.Parse(src)
	if err != nil {
		return nil, err
	}
	return render.Render(root, width, height).ToImage(), nil
}
