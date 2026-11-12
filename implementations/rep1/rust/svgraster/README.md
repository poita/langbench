# svgraster

A small, dependency-free SVG 1.1 subset rasteriser written in Rust. It parses
SVG, flattens shapes and strokes to polygons, scan-converts them with
anti-aliasing and writes binary PPM (`P6`) images composited over white.

Supported: `svg` (viewBox / width / height), `g`, `use`, `path` (all commands,
including arcs), `rect` (with rounded corners), `circle`, `ellipse`, `line`,
`polyline`, `polygon`; `transform`; fill and stroke with opacity, fill rules,
caps, joins and miter limit; `style` attributes, property inheritance,
`currentColor`, the 147 colour keywords, `display` and group `opacity`.
Gradients, clipping, masks, text, patterns, dashes and units other than `px`
are not supported.

Everything — XML, path parsing, curve flattening, stroke outlining and the
scan converter — is implemented in this crate using only the standard library.

## Build

```sh
cargo build --release     # or ./build.sh
cargo test                # unit, integration and doc tests
```

Requires Rust 1.96 or newer. The binary is `target/release/svgraster`.

## Command line

```sh
svgraster <input-dir> <output-dir>     # or ./run.sh <input-dir> <output-dir>
```

`<input-dir>/render.txt` lists the work, one `NAME WIDTH HEIGHT` per line
(`#` comments and blank lines are ignored):

```
# a comment
logo.svg   64 64
banner.svg 200 50
```

For each line, `<input-dir>/NAME` is rendered at the given pixel size and
written to `<output-dir>/NAME-without-.svg.ppm` (`logo.ppm`, `banner.ppm`).
The output directory is created if necessary. The exit status is 0 on
success and non-zero if `render.txt` or any listed file could not be
processed (the remaining files are still rendered).

The view box is stretched to fill the requested size exactly
(`preserveAspectRatio` is ignored).

## Library

```rust
use svgraster::render_svg;

fn main() -> Result<(), svgraster::Error> {
    let svg = r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 4">
        <rect x="1" y="1" width="3.5" height="2" fill="#0000ff"/>
    </svg>"##;

    let canvas = render_svg(svg, 8, 4)?;
    let ppm: Vec<u8> = canvas.to_ppm();          // "P6\n8 4\n255\n" + RGB bytes
    std::fs::write("out.ppm", ppm).unwrap();
    Ok(())
}
```

### Modules

| module | responsibility |
|---|---|
| `xml` | minimal XML parser producing an element arena |
| `number`, `color`, `transform`, `style` | numbers/lengths/opacity, colours, `transform` lists, `style` declarations |
| `path` | path data, elliptical arcs, shape-to-path conversion, cubic flattening |
| `stroke` | stroke outline construction (joins, caps) |
| `raster` | active-edge scan converter with 64 sub-scanlines per pixel row |
| `canvas` | RGBA canvas, source-over and group-opacity compositing, PPM encoding |
| `render` | the document walk: inheritance, `use`, group opacity, painting |
| `jobs` | `render.txt` parsing and the directory driver used by the CLI |

## How it renders

Fills are flattened in device space to 0.01 px; strokes are outlined in user
space (so transforms scale and shear them) and then transformed. Each paint
operation is scan-converted once: edges are sorted by top `y`, an active edge
list is kept in `x` order incrementally, and each of the 64 sub-scanlines per
row is intersected exactly with the polygon, giving coverage accurate to 1/64.
Coverage is accumulated per span in O(1), so work is bounded by the pixels a
shape touches.
