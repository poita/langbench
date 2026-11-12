# svgraster

A small, dependency-free, pure-Python rasteriser for a subset of SVG 1.1. It
parses SVG documents, flattens curves, outlines strokes, fills with
anti-aliased scanline coverage, applies alpha and group-opacity compositing,
and writes binary PPM (P6) images.

Supported: `svg` (document element), `g`, `use`, `path`, `rect`, `circle`,
`ellipse`, `line`, `polyline`, `polygon`; `transform`, `style`, `display`,
`opacity`, and the painting properties `fill`, `fill-opacity`, `fill-rule`,
`stroke`, `stroke-width`, `stroke-linecap`, `stroke-linejoin`,
`stroke-miterlimit`, `stroke-opacity`, `color`. Gradients, clipping, text and
the like are not rendered.

Only the Python standard library is used (plus `pytest` for the tests).

## Layout

| module | responsibility |
|---|---|
| `svgraster.xmlparse` | minimal XML parser producing an element tree |
| `svgraster.values` | numbers, lengths, opacities, `style` declarations |
| `svgraster.colors` | colour parsing and the 147 SVG colour keywords |
| `svgraster.transform` | affine matrices and `transform` lists |
| `svgraster.path` | path data, shapes as paths, arcs, curve flattening |
| `svgraster.stroke` | stroke outlining (segments, joins, caps) |
| `svgraster.raster` | active-edge scanline rasteriser, RGBA canvas, PPM encoding |
| `svgraster.render` | tree walk: inheritance, `use`, group opacity, painting |
| `svgraster.batch` / `svgraster.cli` | `render.txt` processing and the command line |

## Build

There is nothing to compile. `./build.sh` byte-compiles the package; the
project can also be installed with `pip install .` (a `pyproject.toml` /
setuptools layout with sources under `src/`).

## Command line

    ./run.sh <input-dir> <output-dir>
    # or: PYTHONPATH=src python3 -m svgraster <input-dir> <output-dir>

`<input-dir>/render.txt` lists the jobs, one per line, as `NAME WIDTH HEIGHT`
(blank lines and `#` comments are ignored):

    # a comment
    logo.svg 64 64
    banner.svg 200 50

For each line `<output-dir>/<NAME without .svg>.ppm` is written (the output
directory is created if needed). The exit status is 0 on success, 1 if an
input could not be read, and 2 on bad usage.

## Library

```python
from svgraster import render_svg, render_to_ppm

svg = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 4">
  <rect x="1" y="1" width="3.5" height="2" fill="#0000ff"/>
</svg>'''

rgb = render_svg(svg, 8, 4)        # bytes: 8*4*3 RGB values, rows top to bottom
ppm = render_to_ppm(svg, 8, 4)     # a complete P6 file as bytes
with open("out.ppm", "wb") as fh:
    fh.write(ppm)
```

`render_to_canvas(svg, w, h)` returns the underlying `Canvas` (double-precision
RGBA) if you want to inspect it before conversion.

## Tests

    python3 -m pytest

## Method

Shapes become `M/L/C/Z` paths. Fills are flattened in device space to a
0.01 px tolerance; strokes are flattened and outlined in user space (so
transforms scale and shear them), then transformed. Every paint operation is
one scan conversion with 64 sub-scanlines per pixel row, driven by an
active-edge table, so its cost depends on the edges and the area touched
rather than on the canvas size. Group opacity renders into a fresh layer.
