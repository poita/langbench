# svgraster

A small, dependency-free SVG 1.1 rasteriser written in D. It parses a useful
subset of SVG (paths, basic shapes, transforms, `use`, group opacity, fills
and strokes with caps and joins) and renders it with exact-area anti-aliasing
to binary PPM images. It is written from scratch on top of Phobos only: the
XML reader, path parser, curve flattener, stroker and scan converter are all
part of the library.

The package contains

* a library (`source/svgraster/`), split by responsibility, and
* a thin command-line tool (`cli/main.d`) that renders a directory of SVG
  files listed in a `render.txt`.

## Building

Requires LDC (tested with 1.41.0) and dub (tested with 1.40.0).

```sh
./build.sh                      # or: dub build -b release --compiler=ldc2
```

This produces `bin/svgraster`. `run.sh` runs it from any directory.

Unit tests live in `tests/` (separate from the library sources):

```sh
dub test --compiler=ldc2
```

## Command-line use

```
svgraster <input-dir> <output-dir>
```

`<input-dir>/render.txt` lists the files to render, one per line:

```
# NAME WIDTH HEIGHT
logo.svg 64 64
banner.svg 200 50
```

Blank lines and lines starting with `#` are ignored. Each `NAME` is rendered
at `WIDTH` x `HEIGHT` pixels and written to `<output-dir>/NAME.ppm` (a binary
P6 image composited over white). The output directory is created if needed.
The exit status is 0 on success, 1 if an input file could not be read and 2
on a usage error.

The view box is stretched to fill the output (`preserveAspectRatio` is
ignored).

### Supported SVG

Elements `svg`, `g`, `use`, `path`, `rect`, `circle`, `ellipse`, `line`,
`polyline`, `polygon`; attributes `transform`, `style`, `display`, `opacity`,
and the painting properties `fill`, `fill-opacity`, `fill-rule`, `stroke`,
`stroke-width`, `stroke-linecap`, `stroke-linejoin`, `stroke-miterlimit`,
`stroke-opacity` and `color` (with inheritance). Colours: `#rgb`, `#rrggbb`,
`rgb()`, `currentColor`, `none` and the 147 SVG colour keywords. Everything
else (gradients, clipping, masks, filters, text, markers, patterns, CSS
stylesheets, units other than `px`, percentages) is ignored. See the doc
comments in `source/svgraster/render.d` and the module list below for details.

## Library

```d
import std.file : write;
import svgraster;

void main()
{
    enum svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
      <circle cx="50" cy="50" r="40" fill="#e67e22" stroke="#2c3e50" stroke-width="6"/>
      <g opacity="0.5"><rect x="10" y="10" width="40" height="40" fill="blue"/></g>
    </svg>`;

    Image img = renderSvg(svg, 128, 128);      // 8-bit RGB, rows top to bottom
    write("out.ppm", img.toPpm());             // binary P6
}
```

To render many documents, create one `Renderer` and reuse it (it keeps its
scratch buffers), parsing with `parseXml`:

```d
auto renderer = new Renderer;
Image a = renderer.render(parseXml(svgA), 64, 64);
Image b = renderer.render(parseXml(svgB), 64, 64);
```

### Modules

| module | responsibility |
|---|---|
| `svgraster.xml` | tiny XML reader: element tree, attribute entities, `id` map |
| `svgraster.parse` | numbers, lengths, opacities, colours, transform lists, `style` |
| `svgraster.colors` | the colour keyword table |
| `svgraster.geom` | `Vec2`, `Matrix` |
| `svgraster.path` | path model, path-data parser, arcs, cubic flattening |
| `svgraster.shapes` | rect/circle/ellipse/line/poly* to paths |
| `svgraster.stroke` | stroke outlines (segments, joins, caps) as polygons |
| `svgraster.raster` | RGBA `Canvas`, 64-sub-scanline active-edge `Rasterizer` |
| `svgraster.render` | document walk, inheritance, `use`, group opacity, `renderSvg` |
| `svgraster.batch` | `render.txt` parsing and directory rendering |
| `svgraster.buf` | reusable growable buffer |

`import svgraster;` re-exports all of them.

## How it works

Shapes become paths of `M/L/C/Z` segments; arcs and quadratics become cubics.
Fills flatten the path in device space; strokes are outlined in user space
(so transforms scale and skew them) from a user-space flattening, as the
union of segment rectangles, join pieces and caps, then transformed to device
space. Each fill or stroke is a single nonzero/even-odd pass of the
rasteriser: edges are sorted once, an active edge list is swept over 64
sub-scanlines per pixel row, exact span lengths go into per-row `cover`/`delta`
arrays, and finished rows are blended straight into a `double` RGBA canvas.
Group opacity renders into a pooled layer that is composited over its parent.

## License

MIT.
