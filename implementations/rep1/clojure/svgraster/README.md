# svgraster

A small SVG 1.1 rasteriser written in Clojure with no dependencies beyond the
standard library. It parses a subset of SVG (shapes, paths, transforms,
`use`, inherited painting properties, group opacity), flattens curves,
outlines strokes, fills with anti-aliasing and writes binary PPM (P6) images.

It is a library (`svgraster.core`) with a thin command-line tool on top
(`svgraster.main`). The XML parser, path parser, stroker and scan converter are
all implemented here; no SVG, XML, geometry or image library is used.

## Requirements

* Java 27 (any recent JDK works)
* Clojure 1.12.6 and the `clojure` CLI (`deps.edn` project)

## Build

```sh
./build.sh
```

This resolves dependencies and AOT-compiles the command-line tool into
`classes/`. It is optional (it only makes start-up faster); `run.sh` also works
from the sources alone.

## Command line

```sh
./run.sh <input-dir> <output-dir>
# or, without the scripts:
clojure -M -m svgraster.main <input-dir> <output-dir>
```

`<input-dir>/render.txt` lists the files to render, one per line:

```
# comment lines and blank lines are ignored
logo.svg   64  64
banner.svg 200 50
```

Each line is `NAME WIDTH HEIGHT` (sizes 1..4096). For every line,
`<output-dir>/<NAME without .svg>.ppm` is written (the output directory is
created if needed). The exit status is 0 on success; a file that cannot be
rendered is reported on stderr, the remaining files are still rendered, and the
status is then 1.

The view box (or, failing that, the `width`/`height`, or the requested size) is
stretched to fill the output exactly; the image is composited over opaque white.

## Library

```clojure
(require '[svgraster.core :as svg])

;; Render SVG text to an image: {:width 8 :height 4 :pixels <byte[] RGB>}
(def img
  (svg/render-svg
   "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 8 4'>
      <rect x='1' y='1' width='3.5' height='2' fill='#0000ff'/>
    </svg>"
   8 4))

(svg/image->ppm img)                          ; => byte[] holding a P6 file
(svg/render-file "in.svg" 64 64 "out.ppm")    ; file to file
(svg/render-directory "in-dir" "out-dir")     ; the render.txt protocol
```

The modules, from the bottom up:

| namespace | responsibility |
|---|---|
| `svgraster.xml` | minimal XML reader producing `{:tag :attrs :children}` |
| `svgraster.parse` | numbers, lengths, opacities, transform lists, `style` |
| `svgraster.color` | colour values and the 147 SVG colour keywords |
| `svgraster.matrix` | 2D affine matrices |
| `svgraster.path` | path data, arcs, shapes as paths, curve flattening |
| `svgraster.stroke` | stroke outline pieces (segments, joins, caps) |
| `svgraster.raster` | canvas, active-edge scan converter, compositing, PPM |
| `svgraster.render` | document walk: inheritance, `use`, group opacity |
| `svgraster.core` | public API |
| `svgraster.main` | command-line tool |

How it works: every shape becomes a path of `M`/`L`/`C`/`Z` segments. Fills are
flattened in device space (0.01 px tolerance); strokes are flattened in user
space, outlined as a union of convex pieces and then transformed. Each paint
operation goes through one active-edge-table sweep over 64 sub-scanlines per
pixel row; spans are accumulated into pixel coverage with a difference array,
so the cost is proportional to the edges and the pixel rows touched.
Compositing is source-over in sRGB on a double-precision RGBA canvas, and
`opacity` on an element renders its subtree into a fresh layer first.

## Tests

```sh
clojure -X:test
```

runs the unit and property-based tests (Cognitect test-runner, `clojure.test`,
`test.check`) under `test/`. The end-to-end tests live in the repository's
`run_tests.py`.

## Supported subset

Elements `svg` (document element), `g`, `use`, `path`, `rect`, `circle`,
`ellipse`, `line`, `polyline`, `polygon`; properties `fill`, `fill-opacity`,
`fill-rule`, `stroke`, `stroke-width`, `stroke-linecap`, `stroke-linejoin`,
`stroke-miterlimit`, `stroke-opacity`, `color`, `opacity`, `display`, `style`,
`transform`. Gradients, patterns, clipping, masks, filters, markers, text,
nested `svg`, percentages and units other than `px` are not supported.
