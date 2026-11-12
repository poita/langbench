# svgraster

A small SVG 1.1 rasteriser written from scratch in Go, using only the standard
library. It parses a subset of SVG, flattens curves, outlines strokes, fills
with anti-aliasing and writes binary PPM (P6) images. No SVG, XML, path,
geometry or imaging library is involved.

## Supported SVG

* Elements: `svg` (root), `g`, `use`, `path`, `rect` (with `rx`/`ry`), `circle`,
  `ellipse`, `line`, `polyline`, `polygon`. Other elements (`defs`, `text`,
  gradients, clip paths, …) are not drawn, though `use` can reference elements
  inside them by `id`.
* Path data: `M L H V C S Q T A Z` in both cases, implicit repeats, compact
  arc flags.
* Painting: `fill`, `stroke` (colours, `none`, `currentColor`), opacities,
  `fill-rule`, `stroke-width`, `stroke-linecap`, `stroke-linejoin`,
  `stroke-miterlimit`, `opacity` (as a group, via an offscreen layer), `display`,
  `transform`, `style` attributes and `viewBox` (stretched to the output size).
* Colours: `#rgb`, `#rrggbb`, `rgb()` with numbers or percentages and all 147
  SVG colour keywords.

Anti-aliasing uses 64 sub-scanlines per pixel row with exact horizontal span
lengths, driven by an active-edge table, so the cost of a fill depends on the
edges and pixels it touches, not on the canvas size.

## Build

Requires Go 1.27 or newer.

    ./build.sh            # writes bin/svgraster
    go test ./...         # run the unit tests

## Command line

    svgraster <input-dir> <output-dir>
    ./run.sh  <input-dir> <output-dir>      # same, from any directory

`<input-dir>/render.txt` lists the work, one `NAME WIDTH HEIGHT` per line
(`#` comments and blank lines are ignored):

    # a comment
    logo.svg 64 64
    banner.svg 200 50

Each `NAME.svg` in `<input-dir>` is rendered at the given pixel size and
written to `<output-dir>/NAME.ppm`; the output directory is created if needed.
The image is composited over opaque white. The exit status is 0 on success; if
some job fails (say, a missing file) the others are still rendered, the errors
are printed to stderr and the exit status is 1.

## Library

    import "svgraster"

```go
package main

import (
	"log"
	"os"

	"svgraster"
)

func main() {
	src := []byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
  <circle cx="5" cy="5" r="4" fill="#e74c3c" stroke="black" stroke-width="1"/>
</svg>`)

	img, err := svgraster.Render(src, 128, 128) // *svgraster.Image, RGB bytes
	if err != nil {
		log.Fatal(err)
	}
	f, err := os.Create("circle.ppm")
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()
	if err := img.WritePPM(f); err != nil {
		log.Fatal(err)
	}
}
```

`svgraster.RenderDir(in, out)` and `svgraster.ParseJobs(text)` expose the
`render.txt` batch behaviour of the command-line tool.

### Packages

| package | responsibility |
|---|---|
| `svgraster` | top-level `Render`, `RenderDir`, `ParseJobs` |
| `svgraster/xmlmini` | forgiving XML reader (elements and attributes only) |
| `svgraster/svgparse` | numbers, lengths, opacities, colours, transforms, `style` |
| `svgraster/geom` | points and affine matrices |
| `svgraster/path` | path data parser, arcs, shape-to-path, curve flattening |
| `svgraster/stroke` | stroke outline polygons (segments, joins, caps) |
| `svgraster/raster` | active-edge scan converter, RGBA canvas, compositing, PPM output |
| `svgraster/render` | tree walk: inheritance, `use`, group opacity |
| `cmd/svgraster` | the command-line tool |

## Tests

`go test ./...` runs table-driven unit tests for every package plus end-to-end
renderings of small documents. The problem's acceptance suite is run with
`python3 run_tests.py svgraster -- svgraster/run.sh` from the repository root
after `svgraster/build.sh`.
