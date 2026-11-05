// Package svgraster renders a subset of SVG 1.1 to RGB images with
// anti-aliasing, and encodes them as binary PPM.
//
// The renderer is written from scratch on top of the standard library only.
// Its parts live in sub-packages: xmlmini (XML reading), svgparse (values),
// svgpath (paths, arcs, flattening), stroke (stroke outlines), raster
// (canvas, scan conversion, PPM) and render (the tree walk). This package
// ties them together behind a small API.
//
//	img, err := svgraster.Render(svgBytes, 256, 256)
//	if err != nil { ... }
//	os.WriteFile("out.ppm", img.PPM(), 0o644)
package svgraster

import (
	"fmt"
	"strconv"
	"strings"

	"svgraster/raster"
	"svgraster/render"
	"svgraster/xmlmini"
)

// Image is an opaque 8-bit RGB image.
type Image struct {
	Width, Height int
	Pix           []byte // Width*Height*3 bytes, rows top to bottom
}

// PPM encodes the image as a binary P6 file.
func (im *Image) PPM() []byte { return raster.EncodePPM(im.Width, im.Height, im.Pix) }

// Renderer renders many documents while reusing scratch memory. It is not
// safe for concurrent use.
type Renderer struct{ r *render.Renderer }

// NewRenderer returns a ready Renderer.
func NewRenderer() *Renderer { return &Renderer{r: render.New()} }

// Render parses svg and renders it at width x height pixels over a white
// background. The view box (or width/height) is stretched to fill the image.
func (rr *Renderer) Render(svg []byte, width, height int) (*Image, error) {
	if width < 1 || height < 1 {
		return nil, fmt.Errorf("svgraster: invalid size %dx%d", width, height)
	}
	root, err := xmlmini.Parse(svg)
	if err != nil {
		return nil, err
	}
	canvas, err := rr.r.Render(root, width, height)
	if err != nil {
		return nil, err
	}
	return &Image{Width: width, Height: height, Pix: canvas.RGB()}, nil
}

// Render is a convenience wrapper that renders one document with a fresh
// Renderer.
func Render(svg []byte, width, height int) (*Image, error) {
	return NewRenderer().Render(svg, width, height)
}

// Job is one line of a render list: render the SVG file Name at the given
// size into Output.
type Job struct {
	Name          string // input file name, ends in ".svg"
	Width, Height int
	Output        string // output file name: Name without ".svg", plus ".ppm"
}

// ParseJobs parses the text of a render.txt file. Blank lines and lines whose
// first non-space character is '#' are ignored; every other line must be
// "NAME WIDTH HEIGHT".
func ParseJobs(text string) ([]Job, error) {
	var jobs []Job
	for n, line := range strings.Split(text, "\n") {
		line = strings.TrimSuffix(line, "\r")
		t := strings.TrimSpace(line)
		if t == "" || t[0] == '#' {
			continue
		}
		f := strings.Fields(t)
		if len(f) != 3 {
			return nil, fmt.Errorf("line %d: expected NAME WIDTH HEIGHT", n+1)
		}
		w, err1 := strconv.Atoi(f[1])
		h, err2 := strconv.Atoi(f[2])
		if err1 != nil || err2 != nil || w < 1 || h < 1 || w > 4096 || h > 4096 {
			return nil, fmt.Errorf("line %d: bad size %q %q", n+1, f[1], f[2])
		}
		name := f[0]
		if strings.ContainsAny(name, "/\\") || !strings.HasSuffix(name, ".svg") {
			return nil, fmt.Errorf("line %d: bad file name %q", n+1, name)
		}
		jobs = append(jobs, Job{Name: name, Width: w, Height: h, Output: strings.TrimSuffix(name, ".svg") + ".ppm"})
	}
	return jobs, nil
}
