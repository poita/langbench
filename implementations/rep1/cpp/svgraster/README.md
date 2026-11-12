# svgraster

A small, dependency-free C++17 rasteriser for a subset of SVG 1.1. It parses
SVG documents, flattens paths, outlines strokes, fills with 64-sub-scanline
anti-aliasing and writes binary PPM (P6) images. Everything — XML parsing,
path parsing, curve flattening, stroking, scan conversion, compositing — is
implemented here on top of the C++ standard library only.

Supported: `svg` (document element), `g`, `use`, `path`, `rect`, `circle`,
`ellipse`, `line`, `polyline`, `polygon`; `transform`, `style`, `display`,
`opacity` (with group semantics), `fill`, `stroke` and their related
properties (rules, caps, joins, miter limit, opacities, `currentColor`), the
147 SVG colour keywords, `viewBox` (stretched to the output size).

## Layout

| path | contents |
|---|---|
| `include/svgraster/` | public headers (`svgraster.hpp` includes them all) |
| `src/xml.cpp` | minimal XML parser |
| `src/parse.cpp` | numbers, lengths, colours, opacity, transforms, `style` |
| `src/path.cpp`, `src/shapes.cpp` | path data, arcs, flattening; shape → path |
| `src/stroke.cpp` | stroke outline builder (caps, joins, miter limit) |
| `src/raster.cpp` | canvas, active-edge scanline filler, compositing, PPM |
| `src/style.cpp`, `src/render.cpp` | property inheritance; tree walk, `use`, group opacity |
| `cli/main.cpp` | the `svgraster` command |
| `tests/` | GoogleTest unit and rendering tests |

## Build

Requires CMake ≥ 3.20, a C++17 compiler and (for the tests) GoogleTest.

```sh
./build.sh            # Release build into ./build
./build/tests/svgraster_tests    # or: (cd build && ctest)
```

or with plain CMake: `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build`.
Pass `-DSVGRASTER_BUILD_TESTS=OFF` to skip the tests.

## Command line

```
svgraster <input-dir> <output-dir>      # or: ./run.sh <input-dir> <output-dir>
```

`<input-dir>/render.txt` lists one job per line as `NAME WIDTH HEIGHT`
(`#` comments and blank lines are ignored; `1 <= WIDTH, HEIGHT <= 4096`):

```
# a comment
logo.svg 64 64
banner.svg 200 50
```

For each line, `<input-dir>/NAME` is rendered at the given pixel size and written
to `<output-dir>/NAME-without-.svg.ppm` (the directory is created if needed).
Output is always opaque: the drawing is composited over white. The exit status is
0 on success.

## Library example

```cpp
#include <fstream>
#include <svgraster/svgraster.hpp>

int main() {
    const std::string svg =
        "<svg viewBox='0 0 100 100'>"
        "  <circle cx='50' cy='50' r='40' fill='#e67e22' stroke='black' stroke-width='4'/>"
        "</svg>";

    // One call: SVG text -> bytes of a P6 PPM.
    std::string ppm = svgraster::render_svg_to_ppm(svg, 128, 128);
    std::ofstream("circle.ppm", std::ios::binary) << ppm;

    // Or keep the canvas and inspect pixels (premultiplied RGBA doubles).
    svgraster::Canvas canvas = svgraster::render_svg(svg, 128, 128);
    const double* centre = canvas.pixel(64, 64);   // r, g, b, a
    (void)centre;
}
```

Link against the `svgraster` target (`target_link_libraries(app PRIVATE svgraster)`).
The lower-level modules (`parse_xml`, `parse_path_data`, `flatten`,
`stroke_polygons`, `fill_polygons`, …) are public as well.

## How it works

Each file is parsed into an element tree with an `id` map for `use`. A recursive
walk carries the CTM and computed style down the tree. Shapes become paths of
move/line/cubic/close segments (arcs become cubics). Fills are flattened in device
space; strokes are flattened in user space, outlined into pieces (segment
rectangles, join and cap pieces) and mapped to device space. Both go through one
active-edge-table scanline rasteriser: edges are sorted once, the active set is
kept in `x` order by insertion sort across the 64 sub-scanlines of each row, spans
are accumulated per row in O(1) each, and only touched pixels are composited. Group
opacity renders into a fresh layer that is composited back.
