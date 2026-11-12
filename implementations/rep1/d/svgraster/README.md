# svgraster

A small SVG rasteriser written in D with no dependencies beyond Phobos. It
renders a subset of SVG 1.1 (basic shapes, paths with curves and arcs,
transforms, `use`, inherited painting properties, strokes with caps and joins,
group opacity) to binary PPM images, with 64-sub-scanline anti-aliasing.

It is split into a reusable library (`svgraster`) and a thin command-line tool.
Parsing, flattening, stroking and rasterisation are all implemented here; no
SVG, XML, geometry or imaging library is used.

## Building

Requires LDC and dub (developed with LDC 1.41.0 and dub 1.40.0).

```sh
dub build -b release --compiler=ldc2 --config=cli   # or ./build.sh
```

This produces the `svgraster` executable in the project root.

Run the unit tests with:

```sh
dub test --compiler=ldc2
```

## Command-line use

```sh
svgraster <input-dir> <output-dir>      # or ./run.sh <input-dir> <output-dir>
```

`<input-dir>/render.txt` lists the files to render, one per line as
`NAME WIDTH HEIGHT` (blank lines and lines starting with `#` are ignored):

```
# a comment
logo.svg 64 64
banner.svg 200 50
```

For each line the program writes `<output-dir>/<NAME without .svg>.ppm`
(`logo.ppm`, `banner.ppm`), creating the output directory if necessary. The
image is stretched from the document's `viewBox` (or `width`/`height`) to the
requested size and composited over opaque white. The exit status is 0 on
success and non-zero if `render.txt` is unusable or any file fails to render.

## Library use

Add the package as a dependency (`dependency "svgraster" path="../svgraster"`
in `dub.sdl`; dub selects the `library` configuration automatically) and:

```d
import std.file : write;
import svgraster;

void main()
{
    auto canvas = renderSvg(`<svg viewBox="0 0 10 10">
        <circle cx="5" cy="5" r="4" fill="tomato" stroke="navy" stroke-width="0.5"/>
    </svg>`, 64, 64);
    write("circle.ppm", canvas.toPpm());
}
```

`renderSvg(source, width, height)` returns a `Canvas` (premultiplied RGBA,
double precision); `Canvas.toPpm()` composites it over white and encodes P6.
Lower-level building blocks are public too: `parseXml`, `parsePathData`,
`flatten`, `strokeOutline` and `Rasterizer.fill`.

## Layout

| module | responsibility |
|---|---|
| `svgraster.xml` | minimal XML reader (elements and attributes) |
| `svgraster.parse` | numbers, lengths, colours, opacity, transforms, `style` |
| `svgraster.colors` | the 147 SVG colour keywords |
| `svgraster.geom` | `Point` and affine `Matrix` |
| `svgraster.path` | `Path`, elliptical arcs, flattening |
| `svgraster.pathdata` | `d` and `points` parsers |
| `svgraster.shapes` | shapes to paths |
| `svgraster.stroke` | stroke outline pieces (joins, caps) |
| `svgraster.raster` | `Canvas`, active-edge scanline filler, PPM encoder |
| `svgraster.render` | tree walk: inheritance, `use`, group opacity |
| `svgraster.batch` | `render.txt` job lists and directory rendering |
| `app` | the command-line tool |

## Supported subset

Elements `svg` (document element), `g`, `use`, `path`, `rect`, `circle`,
`ellipse`, `line`, `polyline`, `polygon`; properties `fill`, `stroke`,
`stroke-width`, `stroke-linecap`, `stroke-linejoin`, `stroke-miterlimit`,
`fill-rule`, `fill-opacity`, `stroke-opacity`, `opacity`, `color`, `display`,
via attributes or `style`. Gradients, clipping, masks, filters, text and
percentage/unit lengths are not supported.
