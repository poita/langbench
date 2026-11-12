# svgraster

A small, dependency-free SVG 1.1 rasteriser written in Haskell. It parses a
subset of SVG (shapes, paths, transforms, inherited painting properties,
`use`, group opacity), flattens curves, outlines strokes, fills with
anti-aliased scanline coverage and writes binary PPM (`P6`) images. Everything
— XML, path data, geometry, rasterisation — is implemented here; the library
depends only on GHC's bundled packages (`base`, `array`, `bytestring`,
`containers`).

## Building

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh          # cabal build all --enable-tests
cabal test          # run the test suite (hspec + QuickCheck)
```

## Command-line use

```sh
./run.sh <input-dir> <output-dir>
```

`<input-dir>/render.txt` lists the files to render, one per line:

```
# NAME WIDTH HEIGHT
logo.svg 64 64
banner.svg 200 50
```

Blank lines and lines starting with `#` are ignored. For each line the program
reads `<input-dir>/NAME`, renders it at `WIDTH x HEIGHT` pixels (the view box
is stretched to fill the image) and writes `<output-dir>/NAME-without-.svg.ppm`
— here `logo.ppm` and `banner.ppm`. The output directory is created if needed.
The image is composited over opaque white. An SVG that cannot be read or has
no `<svg>` root produces a white image and a warning on stderr; the exit
status is 0 unless `render.txt` itself is unreadable or the arguments are
wrong.

## Supported SVG

Elements: `svg`, `g`, `use` (`href`/`xlink:href`, `x`, `y`), `path`, `rect`
(with `rx`/`ry`), `circle`, `ellipse`, `line`, `polyline`, `polygon`.
`defs`, `symbol`, `text`, gradients, filters, clip paths and the like are not
rendered. Properties: `transform`, `style`, `display`, `opacity`, `fill`,
`fill-opacity`, `fill-rule`, `stroke`, `stroke-width`, `stroke-linecap`,
`stroke-linejoin`, `stroke-miterlimit`, `stroke-opacity`, `color`. Colours are
`#rgb`, `#rrggbb`, `rgb()`, `currentColor`, `none` and the 147 SVG colour
keywords. All path commands, including arcs, are supported.

## Library

The library is organised by responsibility; each module is documented with
Haddock (`cabal haddock`).

| module | responsibility |
|---|---|
| `Graphics.SVG.Raster` | high-level API: `renderToPPM`, render-list parsing |
| `Graphics.SVG.Raster.Xml` | minimal XML parser |
| `Graphics.SVG.Raster.Parse` | numbers, lengths, paints, opacity, transforms, `style` |
| `Graphics.SVG.Raster.Color` | the colour keyword table |
| `Graphics.SVG.Raster.Geometry` | points and affine matrices |
| `Graphics.SVG.Raster.Path` | path data, arcs, shapes, curve flattening |
| `Graphics.SVG.Raster.Stroke` | stroke outlining (caps, joins) |
| `Graphics.SVG.Raster.Canvas` | RGBA canvas, active-edge scanline filler, compositing, PPM |
| `Graphics.SVG.Raster.Render` | document walk, inheritance, `use`, group opacity |

### Example

```haskell
import qualified Data.ByteString as BS
import Graphics.SVG.Raster

main :: IO ()
main = do
  let svg = "<svg viewBox='0 0 8 4'>\
            \<rect x='1' y='1' width='3.5' height='2' fill='#00f'/></svg>"
  case renderToPPM 8 4 svg of
    Right ppm -> BS.writeFile "out.ppm" ppm
    Left err  -> putStrLn ("cannot render: " ++ err)
```

Lower-level pieces can be used on their own, e.g. flattening a path and
filling it onto a canvas:

```haskell
import Control.Monad.ST (runST)
import Graphics.SVG.Raster.Canvas
import Graphics.SVG.Raster.Geometry
import Graphics.SVG.Raster.Path

ppm = runST $ do
  cv <- newCanvas 32 32
  let subpaths = flattenPath identity (ellipsePath 16 16 12 8)
  fillPolygons cv NonZero (1, 0, 0) 1 (map spPoints subpaths)
  canvasToPPM cv
```

## How it renders

* Curves and arcs become cubics and are flattened to 0.01 device pixels.
* Fills are flattened in device space; strokes are outlined in user space as a
  union of segment rectangles, join pieces and cap pieces, then transformed.
* Coverage comes from an active-edge sweep over 64 sub-scanlines per pixel
  row, with exact spans accumulated per row, so the cost of a fill scales with
  the edges and pixels it touches rather than the canvas size.
* Compositing is source-over in non-linear sRGB; `opacity` on a group or shape
  renders into an offscreen layer.

## License

MIT.
