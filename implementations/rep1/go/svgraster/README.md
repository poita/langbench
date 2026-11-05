# svgraster

A small SVG rasteriser written in Go using only the standard library. It
renders a subset of SVG 1.1 — `svg`, `g`, `use`, `path`, `rect`, `circle`,
`ellipse`, `line`, `polyline`, `polygon`, with fill, stroke (caps, joins,
miter limit), `fill-rule`, `transform`, `style`, `display`, and per-element
and per-paint opacity — to anti-aliased binary PPM images.

XML parsing, path parsing, arc conversion, curve flattening, stroke
outlining, scan conversion and compositing are all implemented here; no SVG,
XML, geometry or image library is used. Anti-aliasing uses 64 exactly
intersected sub-scanlines per pixel row, driven by an active-edge table.

## Build

Requires Go 1.27 or later.

```sh
./build.sh          # or: go build -o bin/svgraster ./cmd/svgraster
go test ./...       # unit tests
```

## Command line

```sh
./run.sh <input-dir> <output-dir>
```

`<input-dir>/render.txt` lists the files to render, one per line:

```
# NAME WIDTH HEIGHT
logo.svg 64 64
banner.svg 200 50
```

For each line the program renders `<input-dir>/NAME` at WIDTH x HEIGHT pixels
(the view box is stretched to fit; `preserveAspectRatio` is ignored) over a
white background and writes `<output-dir>/NAME-without-.svg.ppm`. The output
directory is created if needed. Exit status is 0 on success; a file that
cannot be read or is not an SVG document is reported on stderr and makes the
exit status 1 (the remaining files are still rendered).

## Library

The library is split by responsibility:

| package | role |
|---|---|
| `svgraster` | top-level API: `Render`, `Renderer`, `Image`, `ParseJobs` |
| `xmlmini` | minimal XML reader (elements and attributes) |
| `svgparse` | numbers, lengths, opacity, colours, transforms, `style` |
| `svgpath` | path data, shapes, elliptical arcs, cubic flattening |
| `stroke` | stroke outlines (rectangles + joins + caps) |
| `raster` | canvas, scanline filler, group compositing, PPM |
| `render` | tree walk: inheritance, `use`, group opacity, painting |
| `geom` | points, affine matrices, polygon buffers |

Example:

```go
package main

import (
	"os"

	"svgraster"
)

func main() {
	svg := []byte(`<svg viewBox="0 0 10 10">
	  <circle cx="5" cy="5" r="4" fill="tomato" stroke="navy" stroke-width="1"/>
	</svg>`)

	img, err := svgraster.Render(svg, 100, 100)
	if err != nil {
		panic(err)
	}
	// img.Pix holds 100*100*3 RGB bytes; PPM() wraps them in a P6 header.
	if err := os.WriteFile("circle.ppm", img.PPM(), 0o644); err != nil {
		panic(err)
	}
}
```

To render many documents, create one `svgraster.NewRenderer()` and reuse it so
scratch buffers are shared. A `Renderer` is not safe for concurrent use.
