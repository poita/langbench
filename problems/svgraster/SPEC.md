# SVG rasteriser

Write a program that renders a subset of SVG 1.1 to binary PPM images.

    <program> <input-dir> <output-dir>

The program reads `<input-dir>/render.txt`, renders every SVG file it names at
the requested pixel size, and writes one `.ppm` file per SVG into
`<output-dir>`. Nothing is read from stdin, nothing is written outside
`<output-dir>`, and the program exits with status 0 on success.

This is a real rasteriser: XML parsing, path parsing, curve flattening, stroke
outlining, scanline filling with anti-aliasing and alpha compositing. A
complete implementation is roughly 1200–2000 lines.

Write the parsing and rendering yourself: don't use an SVG, XML, path,
geometry, rasterisation or image library, or such routines from the standard
library or the language.

---

## 1. The input directory

`render.txt` is UTF-8 text. Lines are separated by `\n` (a trailing `\r` is
stripped). A line whose first non-space character is `#`, and a line that is
empty or all spaces, is ignored. Every other line has exactly three
whitespace-separated fields:

    NAME WIDTH HEIGHT

* `NAME` is the name of a file in `<input-dir>`. It contains no `/` and always
  ends in `.svg` (lower case).
* `WIDTH` and `HEIGHT` are decimal integers, `1 <= WIDTH, HEIGHT <= 4096`.

The lines are processed in order. The output file for a line is
`<output-dir>/<NAME with the trailing ".svg" removed>.ppm`. Names are unique
within a `render.txt`. The output directory already exists, or must be created
by the program.

Example `render.txt`:

    # a comment
    logo.svg 64 64
    banner.svg 200 50

produces `logo.ppm` and `banner.ppm`.

## 2. The output file

Binary PPM ("P6"). The file is exactly:

    P6\n<WIDTH> <HEIGHT>\n255\n

(the width and height in decimal, one ASCII space between them, `\n` after
each of the three lines) followed by `WIDTH * HEIGHT * 3` bytes: rows top to
bottom, within a row pixels left to right, within a pixel the red, green and
blue bytes. There is nothing after the pixel data.

The image is always fully opaque: the rendering is composited over an opaque
white background (see §8).

---

## 3. XML parsing

Input documents are well-formed XML using only elements and attributes. A
conforming parser is not required; the following is sufficient and is exactly
what the tests need:

* Skip `<?...?>` processing instructions, `<!-- ... -->` comments,
  `<!DOCTYPE ...>` (including an internal `[...]` subset) and `<![CDATA[...]]>`
  sections.
* A start tag is `<name attrs>` or `<name attrs/>`; an end tag is `</name>`.
  `>` inside a quoted attribute value does not end the tag.
* An attribute is `name = "value"` or `name = 'value'`, with optional spaces
  around `=`. Attribute values contain no `<`.
* Character data between tags is ignored (no text is rendered).
* Namespace prefixes are stripped from element and attribute names, so
  `xlink:href` is treated as `href` and `svg:rect` as `rect`. Namespace
  declarations (`xmlns`, `xmlns:*`) are ignored, as is any attribute this spec
  does not list.
* In attribute values, resolve the entities `&amp; &lt; &gt; &quot; &apos;` and
  numeric references `&#NNN;` / `&#xHHH;`. Any other `&...;` is left as is.
* When two attributes on one element have the same stripped name, the last one
  wins.

The document element is the first start tag in the file and is `<svg>`.

## 4. Numbers, lengths, colours, opacity

**Number.** Optional sign, then digits with an optional `.` and fraction part
(`.5`, `5.`, `5`, `5.25` are all valid; at least one digit must be present in
the integer or the fraction part), then an optional exponent `e`/`E` with an
optional sign and at least one digit. An exponent that is not followed by a
digit is not part of the number.

**Length.** A number optionally followed by `px`. Leading and trailing
whitespace is allowed. No other unit and no percentage appears in the test
inputs, on any attribute or property, including the document element's `width`
and `height`. A missing attribute, or one whose value does not start with a
number, means the default given for that attribute below.

**Colour.** One of

* `none` — the shape is not painted with this paint.
* `currentColor` — the current value of the `color` property (§6); matched
  case-insensitively.
* `#rgb` — three hex digits, each doubled: `#f39` is `#ff3399`.
* `#rrggbb` — six hex digits.
* `rgb(` r `,` g `,` b `)` — the three components separated by commas and/or
  whitespace. Each component is either a number (clamped to `[0, 255]`, then
  rounded to the nearest integer, halves away from zero) or a number followed
  by `%` (clamped to `[0, 100]`, multiplied by `255/100`, then rounded the same
  way). Components may not mix forms in the test inputs.
* A colour keyword from the SVG 1.1 list of 147 names (`aliceblue` …
  `yellowgreen`), matched case-insensitively. The full list with its hex values
  is the one in the SVG 1.1 specification, §4.4 "Recognized color keyword
  names".

Hex digits are matched case-insensitively. All test inputs use only the colour
values listed above; no `url(...)` paint reference, no `inherit`, and no colour
value outside this grammar appears. The result is an 8-bit sRGB triple; divide
by 255 to get the channel values used in §8.

**Opacity.** A number, or a number followed by `%` (divided by 100), clamped to
`[0, 1]`. A value that is not of that form (anything left over after the number
other than `%`, or no number at all) is ignored and the property keeps its
initial value, which is `1` for `opacity`, `fill-opacity` and
`stroke-opacity`.

## 5. Elements

These elements are rendered, in document order (painter's algorithm — later
elements paint over earlier ones):

| element | attributes used |
|---|---|
| `svg` (document element only) | `width`, `height`, `viewBox` |
| `g` | — |
| `use` | `href`, `x`, `y` |
| `path` | `d` |
| `rect` | `x`, `y`, `width`, `height`, `rx`, `ry` |
| `circle` | `cx`, `cy`, `r` |
| `ellipse` | `cx`, `cy`, `rx`, `ry` |
| `line` | `x1`, `y1`, `x2`, `y2` |
| `polyline` | `points` |
| `polygon` | `points` |

Every one of them also uses `transform`, `style`, `display`, `opacity` and the
painting properties of §6.

These elements are **not** rendered, and neither are their descendants:
`defs`, `symbol`, `clipPath`, `mask`, `title`, `desc`, `style`, `metadata`,
`marker`, `pattern`, `linearGradient`, `radialGradient`, `filter`, `text`, and
any element not named in this section. Their descendants are still visible to
`use` (they can be referenced by `id`).

**`display`.** The computed `display` of an element is the value from its
`style` attribute if that declares `display`, else the value of the `display`
presentation attribute, else absent — the same precedence as §6, so
`display="none" style="display:inline"` is **visible**. If the computed value
is exactly `none`, the element and its descendants are not rendered. `display`
is not inherited: a descendant that sets `display` to something else is still
hidden because its ancestor was skipped.

A nested `<svg>` element (an `svg` that is not the document element) does not
appear in the test inputs, and neither does `switch`, `foreignObject` or `image`.

**`use`.** `href` (or `xlink:href`) is `#id`. The referenced element is looked
up by `id` over the whole document (the first element with that `id` in
document order wins). If nothing matches, the `use` renders nothing.
Referenced elements are `g` or one of the seven shapes. The referenced element
is rendered as if it were a child of the `use` element, after the `use`
element's own `transform` and then a `translate(x, y)` (defaults `0`).
Painting properties are inherited into the referenced element from the `use`
element in the usual way (§6), so a property set on the referenced element
itself still wins. Nesting deeper than 64 levels (counting `use` expansion) is
not rendered; the test inputs never nest that deeply and contain no reference
cycles.

## 6. Painting properties

The following properties are **inherited**: `fill`, `fill-opacity`,
`fill-rule`, `stroke`, `stroke-width`, `stroke-linecap`, `stroke-linejoin`,
`stroke-miterlimit`, `stroke-opacity`, `color`. Their initial values (used at
the document element when nothing sets them) are:

| property | initial |
|---|---|
| `fill` | `black` |
| `fill-opacity` | `1` |
| `fill-rule` | `nonzero` |
| `stroke` | `none` |
| `stroke-width` | `1` |
| `stroke-linecap` | `butt` |
| `stroke-linejoin` | `miter` |
| `stroke-miterlimit` | `4` |
| `stroke-opacity` | `1` |
| `color` | `black` |

For each element, the computed value of an inherited property is: the value
from the element's `style` attribute if present there, else the value of the
presentation attribute of the same name if present, else the value inherited
from the parent element.

The `style` attribute is a list of `name : value` declarations separated by
`;`. Empty declarations and declarations without a `:` are ignored. A `style`
value in the test inputs may contain empty declarations in the middle or at
the end (`a:b;;c:d;`) but never a leading `;`, and every declaration it
contains has a `:`. Property names and values
are trimmed of surrounding whitespace. Property names are matched
case-insensitively; every property name in the test inputs is lower case. `!important` does not appear in the test inputs, nor
does a `<style>` stylesheet affect rendering.

A declaration whose value is empty after trimming (`fill:`) is ignored too, so
the property falls back to the presentation attribute or to the inherited
value. Property *values* are matched case-sensitively — `fill-rule="EVENODD"`
is not `evenodd` and is therefore treated as the initial value — except for
colour keywords, `currentColor`, `none` and hex digits, which §4 matches
case-insensitively. Every keyword value in the test inputs is lower case.

`opacity` is **not** inherited; it applies to the element it is written on (see
§8). Its initial value is `1`. It too may come from the `style` attribute,
which takes precedence over the attribute.

`stroke-width` values are lengths in the element's own user coordinate system.
`stroke-linecap` must be `butt`, `round` or `square`; `stroke-linejoin` must be
`miter`, `round` or `bevel`; `fill-rule` must be `nonzero` or `evenodd`. Any
other value is treated as the initial value of that property.

## 7. Geometry

### 7.1 The viewport transform

Let `W`, `H` be the pixel size from `render.txt`. Determine the user
coordinate rectangle `(vx, vy, vw, vh)`:

1. If the document element has a `viewBox` attribute containing at least four
   numbers (separated by whitespace and/or commas) and the third and fourth are
   both `> 0`, use the first four numbers.
2. Otherwise, if its `width` and `height` attributes both parse to lengths
   `> 0`, use `(0, 0, width, height)`.
3. Otherwise use `(0, 0, W, H)`.

The viewport transform is

    sx = W / vw,  sy = H / vh
    CTM0 = [ sx  0   -vx*sx
             0   sy  -vy*sy ]

i.e. the view box is **stretched** to fill the output exactly;
`preserveAspectRatio` is ignored. (In practice the tests request sizes whose
aspect ratio matches the view box, except for one test that deliberately does
not.) Device space has `x` increasing to the right and `y` increasing
downwards; pixel `(i, j)` (column `i`, row `j`) is the unit square
`[i, i+1] x [j, j+1]`.

### 7.2 Transforms

A `transform` attribute is a list of transform functions separated by
whitespace and/or commas. Each is `name(args)` where the arguments are numbers
separated by whitespace and/or commas:

| function | matrix `[a c e; b d f]` |
|---|---|
| `matrix(a b c d e f)` | as given |
| `translate(tx [ty])` | `[1 0 tx; 0 1 ty]`, `ty` defaults to `0` |
| `scale(sx [sy])` | `[sx 0 0; 0 sy 0]`, `sy` defaults to `sx` |
| `rotate(a [cx cy])` | rotate by `a` degrees about `(cx, cy)`, default `(0,0)` |
| `skewX(a)` | `[1 tan(a) 0; 0 1 0]` |
| `skewY(a)` | `[1 0 0; tan(a) 1 0]` |

Every function in the test inputs is one of the six above and carries a valid
number of arguments (`matrix` 6, `translate` 1 or 2, `scale` 1 or 2, `rotate`
1 or 3, `skewX`/`skewY` 1); a function with too few arguments is skipped.

`rotate(a)` is `[cos -sin 0; sin cos 0]` (positive angles turn from the `+x`
axis towards the `+y` axis, i.e. clockwise on screen). `rotate(a cx cy)` is
`translate(cx,cy) rotate(a) translate(-cx,-cy)`. An unknown function name is
skipped. Functions compose left to right: the list `f g` is the matrix
`F * G`, so `g` applies to the coordinates first.

The current transformation matrix for an element is
`CTM(parent) * transform(element)`; the document element's parent transform is
`CTM0`. The document element itself never carries a `transform` attribute in
the test inputs.

### 7.3 Shapes as paths

Every shape is converted to a path in the element's user coordinate system.
Path commands are written here as `M x y`, `L x y`, `C x1 y1 x2 y2 x y` and
`Z`, which is all a renderer needs.

**`rect`** with `x`, `y` (default `0`), `width`, `height` (default `0`),
`rx`, `ry`: nothing is drawn if `width <= 0` or `height <= 0`. If neither `rx`
nor `ry` is present (or both are the string `auto`), both are `0`; if only one
is present the other takes its value. Negative values are treated as `0`. Then
`rx = min(rx, width/2)` and `ry = min(ry, height/2)`. If either is `0` the path
is the plain rectangle

    M x y  L x+w y  L x+w y+h  L x y+h  Z

Otherwise it is the rounded rectangle, going clockwise from the top-left
corner's end of the top edge:

    M x+rx y  L x+w-rx y  A(rx,ry) to (x+w, y+ry)
    L x+w y+h-ry          A(rx,ry) to (x+w-rx, y+h)
    L x+rx y+h            A(rx,ry) to (x, y+h-ry)
    L x y+ry              A(rx,ry) to (x+rx, y)  Z

where each `A` is an elliptical arc with `x-axis-rotation = 0`,
`large-arc-flag = 0`, `sweep-flag = 1` (§7.5).

**`circle`** with `cx`, `cy` (default `0`) and `r` (default `0`): nothing if
`r <= 0`, else the ellipse below with `rx = ry = r`.

**`ellipse`** with `cx`, `cy` (default `0`) and `rx`, `ry` (default `0`):
nothing if `rx <= 0` or `ry <= 0`, else

    M cx+rx cy
    A(rx,ry, 0, 0, 1) to (cx, cy+ry)
    A(rx,ry, 0, 0, 1) to (cx-rx, cy)
    A(rx,ry, 0, 0, 1) to (cx, cy-ry)
    A(rx,ry, 0, 0, 1) to (cx+rx, cy)
    Z

**`line`**: `M x1 y1  L x2 y2` (defaults `0`). It has no interior, so it is
never filled.

**`polyline` / `polygon`**: `points` is a list of numbers separated by
whitespace and/or commas. An odd trailing number is discarded. With `n >= 1`
points the path is `M p0 L p1 ... L p(n-1)`, plus a final `Z` for `polygon`.
With no points nothing is drawn.

### 7.4 Path data

`d` is parsed as a sequence of commands. Whitespace and commas separate tokens
and may be omitted where the parse is unambiguous. A command letter may be
followed by several parameter groups, repeating the command; after `M`/`m` the
repeats are `L`/`l`. Parsing stops at the first token that is not the expected
kind; commands parsed before that point are kept and drawn.

The **arc flags** `large-arc-flag` and `sweep-flag` are single characters `0`
or `1`, not general numbers: in `a5 5 0 0110 10` the flags are `0` and `1` and
the following number is `10`.

Commands, with `(cx, cy)` the current point and lower case meaning the
parameters are offsets from the current point:

* `M`/`m` `x y` — start a new subpath at the point; it becomes the subpath's
  start point.
* `L`/`l` `x y`, `H`/`h` `x`, `V`/`v` `y` — straight line; `H` keeps `cy`,
  `V` keeps `cx`.
* `C`/`c` `x1 y1 x2 y2 x y` — cubic Bézier.
* `S`/`s` `x2 y2 x y` — cubic whose first control point is the reflection of
  the previous command's second control point about the current point, or the
  current point itself when the previous command was not `C`, `c`, `S` or `s`.
* `Q`/`q` `x1 y1 x y` — quadratic Bézier. It is exactly equal to the cubic with
  controls `c + 2/3 (q - c)` and `e + 2/3 (q - e)`, where `c` is the current
  point, `q` the quadratic control point and `e` the end point; converting it
  this way is required so that curve flattening matches.
* `T`/`t` `x y` — quadratic whose control point is the reflection of the
  previous command's control point about the current point, or the current
  point itself when the previous command was not `Q`, `q`, `T` or `t`.
* `A`/`a` `rx ry rot large-arc sweep x y` — elliptical arc (§7.5).
* `Z`/`z` — close the current subpath; the current point returns to the
  subpath's start point. `Z` before any `M` does nothing. `Z` takes no
  parameters and does not repeat, so a number following it is not an expected
  token and stops the parse.

A `Z` with no `M` after it ends the subpath; a following drawing command starts
a new subpath at the start point of the closed one. Every path in the test inputs starts with `M` or `m`.

### 7.5 Elliptical arcs

Convert the endpoint parameterisation to centre parameterisation exactly as in
the SVG 1.1 implementation notes, §F.6.5 and §F.6.6:

1. If the start and end points are equal, the arc is dropped entirely.
2. `rx = |rx|`, `ry = |ry|`. If either is `0`, the arc is a straight line to
   the end point.
3. Compute `(x1', y1')` by §F.6.5.1, then the radii correction §F.6.6.2: if
   `L = x1'^2/rx^2 + y1'^2/ry^2 > 1`, scale both radii by `sqrt(L)`.
4. Compute the centre `(cx, cy)` by §F.6.5.2–3 and the angles `theta1` and
   `dtheta` by §F.6.5.5–6, with `dtheta` adjusted into `(0, 2pi)` when
   `sweep = 1` and into `(-2pi, 0)` when `sweep = 0`.

Then approximate the arc with `n = ceil(|dtheta| / (pi/4))` (at least 1) cubic
segments of equal angular extent `delta = dtheta / n`. When `|dtheta|` is an
exact multiple of `pi/4` (a quarter-circle arc, for instance) rounding may make
that ceiling one larger; either value is acceptable, because the two
approximations of the same arc differ by far less than the flattening
tolerance of §7.6. Segment `k` runs from
angle `t0 = theta1 + k*delta` to `t1 = t0 + delta`; with
`E(t) = C + R(phi) * (rx cos t, ry sin t)` and
`E'(t) = R(phi) * (-rx sin t, ry cos t)` (where `R(phi)` is the rotation by
the `x-axis-rotation` in radians and `C` the centre), the cubic is

    P0 = E(t0)                 P1 = E(t0) + k * E'(t0)
    P3 = E(t1)                 P2 = E(t1) - k * E'(t1)
    k  = 4/3 * tan(delta/4)

with `P0` of the first segment replaced by the exact start point and `P3` of
the last segment replaced by the exact end point.

### 7.6 Flattening

Each cubic is replaced by a polyline. Any subdivision is acceptable as long as
every point of the cubic lies within **0.01 device pixels** of the polyline.
(The reference subdivides a cubic with device-space control points
`P0..P3` into `n = ceil(sqrt(0.75 * sqrt(m) / 0.01))` equal steps in `t`, where
`m = max(|P0 - 2P1 + P2|^2, |P1 - 2P2 + P3|^2)`, capped at 1000.)

A subpath is a maximal run of commands starting at an `M`; it is *closed* when
it ended with `Z`. Filling closes every subpath implicitly; stroking does not.

## 8. Painting

A shape is painted in two steps, fill first and then stroke, each as an
independent source-over composite onto the canvas.

### 8.1 Fill

If the computed `fill` is `none`, or `fill-opacity` is `0`, nothing is filled.
Otherwise take all subpaths of the shape's path, transformed into device space
by the element's CTM and flattened, treat each as a closed polygon, and
determine the filled region by the `fill-rule`:

* `nonzero`: a point is inside when the sum of the signed crossings of a ray
  from it is not zero (`+1` for an edge crossing downwards, `-1` upwards).
* `evenodd`: a point is inside when the number of crossings is odd.

Subpaths with fewer than three distinct points enclose no area.

### 8.2 Stroke

If the computed `stroke` is `none`, or `stroke-width <= 0`, or
`stroke-opacity` is `0`, nothing is stroked.

The stroke outline is built in the element's **user** coordinate system (so a
transform scales and shears the stroke), then transformed into device space by
the CTM. Let `w` be `stroke-width` and `r = w/2`. The centreline is flattened
first (§7.6); its tolerance, like every tolerance here, is 0.01 **device**
pixels, so in user space it is that divided by the scale the CTM applies.

For each subpath, take its flattened points, drop points equal to their
predecessor, and for a closed subpath drop a final point equal to the first.
Let the resulting points be `p0 .. p(n-1)`; a closed subpath has `n` segments
(`p(n-1)` to `p0` included), an open one has `n-1`.

The stroke region is the **union** of these pieces:

1. For each segment from `a` to `b`: the rectangle
   `a+N, b+N, b-N, a-N` where `N` is the segment direction rotated a quarter
   turn and scaled to length `r`.
2. For each *joint* — every `p_i` that has a segment on both sides, which for a
   closed subpath includes `p0` — a join piece. Let `d0` and `d1` be the unit
   directions of the incoming and outgoing segments, `cross = d0 x d1`,
   `dot = d0 . d1`, and `s = +1` if `cross > 0` else `-1`. The two outer offset
   points are `A = p + s*(d0.y, -d0.x)*r` and `B = p + s*(d1.y, -d1.x)*r`.
   If `cross == 0` and `dot > 0` there is no join piece. Otherwise:
   * `round`: the circular sector `p, A, ..., B` swept along the circle of
     radius `r` about `p`. The sweep angle is the signed angle from `A - p` to
     `B - p` in `(-pi, pi]`, except that when `cross == 0` (an exact reversal)
     it is `s * pi`, which puts the half disc on the side the segments miss.
   * `miter`: with `ratio = 1 / sqrt((1 + dot) / 2)` (the miter length divided
     by `r`), if `dot > -1` and `cross != 0` and `ratio <= stroke-miterlimit`,
     the quadrilateral `p, A, M, B` where `M` is the intersection of the two
     offset lines (the line through `A` along `d0` and the line through `B`
     along `d1`). Otherwise the `bevel` piece.
   * `bevel`: the triangle `p, A, B`.
   `stroke-miterlimit` is clamped to a minimum of `1`.
3. For each end of an *open* subpath (only when `n >= 2`), with `p` the end
   point and `u` the unit direction pointing out of the subpath:
   * `butt`: nothing.
   * `square`: the rectangle `p+N, p+N+u*r, p-N+u*r, p-N`, `N` being `u`
     rotated a quarter turn and scaled to `r`.
   * `round`: the half disc of radius `r` about `p` on the `u` side.
4. A subpath that has only one distinct point draws nothing for `butt`, a
   full disc of radius `r` for `round`, and the axis-aligned square of side `w`
   centred on the point for `square`. This means a subpath that *has* drawing
   commands but collapses to a point, such as `M10 10 L10 10` or `M10 10 Z`. A
   lone `M` with no drawing command after it is not a subpath at all: it
   contributes no geometry to either the fill or the stroke.

The union is computed by filling all the pieces together with the **nonzero**
rule after orienting each piece so its signed area is positive. Circular arcs
(round joins and caps) are approximated by polylines within 0.01 device pixels,
as in §7.6.

### 8.3 Coverage and compositing

The canvas is `W x H` pixels of straight-alpha RGBA, all channels starting at
`0` (transparent).

For one paint operation (a fill or a stroke) with colour `(cr, cg, cb)` in
`[0,1]` and paint opacity `pa` (the `fill-opacity` or `stroke-opacity`), the
**coverage** of pixel `(i, j)` is the area of the intersection of the region
being painted with the pixel's unit square. The pixel is then updated with
source-over compositing in non-linear sRGB space, with
`alpha = pa * coverage`:

    dst.r = cr*alpha + dst.r*(1 - alpha)      (same for g and b)
    dst.a =    alpha + dst.a*(1 - alpha)

An implementation does not have to compute the area exactly, but it must come
within `1/64` of it for every pixel. The reference divides each pixel row into
**64 equally spaced horizontal sub-scanlines** (sub-scanline `k` of row `j`
samples at `y = j + (k + 0.5)/64`), intersects the region with each
sub-scanline exactly to get a set of `x` spans, and takes the coverage of a
pixel to be the mean over the 64 sub-scanlines of the length of the spans
clipped to the pixel's `x` range. That scheme reaches the required accuracy
from 32 sub-scanlines upwards; eight sub-scanlines is measurably too coarse and
fails the comparison of §9, and so does point sampling on a 4x4 grid (16
samples per pixel), because it quantises coverage to multiples of `1/16`.
Analytic area coverage is exact and therefore always within tolerance.

All arithmetic is done in IEEE double precision.

### 8.4 Group opacity

If an element's computed `opacity` is `0` it and its subtree are not rendered.
If it is `1` the element renders directly onto the current canvas. If it is
strictly between, the element and its subtree are rendered onto a **fresh
transparent canvas** of the same size, which is then composited onto the
current canvas with

    dst.r = src.r*o + dst.r*(1 - src.a*o)     (same for g and b)
    dst.a = src.a*o + dst.a*(1 - src.a*o)

where `o` is the opacity. On a shape element this makes the fill and the
stroke fade as one object instead of separately.

### 8.5 Output conversion

After the whole document is rendered, each pixel is composited over opaque
white and converted to bytes:

    v = channel + (1 - dst.a)              for each of r, g, b
    byte = floor(clamp(v, 0, 1) * 255 + 0.5)

(`channel` is the straight-alpha value already multiplied by `dst.a`, i.e. the
value the recurrences of §8.3 produce.)

---

## 9. Comparison tolerance

Output is not compared byte for byte. `verify.py` checks that each produced
`.ppm` has the expected P6 header and dimensions, and then that, against the
expected image:

* no more than **0.5%** of pixels (but always at least one pixel) have any
  channel differing by more than **8**, and
* the mean absolute difference over all channels is below **1.0**.

The tolerance exists for anti-aliasing and rounding differences only. Getting
the geometry, the winding rule, the colours or the compositing wrong will not
pass: an edge misplaced by half a pixel across a large shape already exceeds
the pixel budget.

---

## 10. Worked examples

### 10.1 A rectangle with a fractional edge

`in.svg`:

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 4" width="8" height="4">
  <rect x="1" y="1" width="3.5" height="2" fill="#0000ff"/>
</svg>
```

`render.txt`: `in.svg 8 4`. The view box is `8 x 4` and the output is `8 x 4`,
so one user unit is one pixel. Row 1 of the image (0-based) is:

| pixel | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| coverage | 0 | 1 | 1 | 1 | 0.5 | 0 | 0 | 0 |
| bytes | `ff ff ff` | `00 00 ff` | `00 00 ff` | `00 00 ff` | `80 80 ff` | `ff ff ff` | `ff ff ff` | `ff ff ff` |

Pixel `(4, 1)` has coverage `0.5`, so `r = 0*0.5 + 0*0.5 = 0`, `a = 0.5`, and
the output red byte is `floor((0 + 0.5) * 255 + 0.5) = floor(128.0) = 128 =
0x80`. Rows 0 and 3 are entirely white.

### 10.2 Scaling and a stroke

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10" width="10" height="10">
  <g transform="scale(2)">
    <rect x="1" y="1" width="3" height="3" fill="none" stroke="black" stroke-width="1"/>
  </g>
</svg>
```

rendered at `40 x 40`. `CTM0` scales by `4`, the group scales by `2`, so the
element CTM scales by `8`. The stroke is outlined in user space with width `1`
around the rectangle from `(1,1)` to `(4,4)`, i.e. the region between the
squares `(0.5,0.5)-(4.5,4.5)` and `(1.5,1.5)-(3.5,3.5)`. In device space those
are `(4,4)-(36,36)` and `(12,12)-(28,28)`: a black frame 8 pixels thick with
crisp edges (every edge lands on an integer), no anti-aliasing visible.

### 10.3 Fill rule

```xml
<path fill="#8e44ad" fill-rule="evenodd"
      d="M10 0 L16 18 L0 7 L20 7 L4 18 Z"/>
```

The five-pointed star's central pentagon has winding number `2`, so it is
painted with `nonzero` and left unpainted with `evenodd`.

### 10.4 Group opacity is not per-shape opacity

```xml
<g opacity="0.5">
  <circle cx="20" cy="20" r="15" fill="red"/>
  <circle cx="30" cy="20" r="15" fill="blue"/>
</g>
```

In the overlap the blue circle fully covers the red one *inside the group*, so
the result over white is `0.5*blue + 0.5*white`. Writing `opacity="0.5"` on
each circle instead gives `0.5*blue + 0.5*(0.5*red + 0.5*white)` there — a
visibly different colour. §8.4 must be implemented with an offscreen canvas.

---

## 11. Suggested architecture

* **xml.\*** — the tiny non-validating parser of §3, producing a tree of
  `(tag, attrs, children)`.
* **parse.\*** — numbers, lengths, colours (with the 147-name table),
  transform lists, style declarations.
* **path.\*** — the path-data scanner of §7.4, arc conversion (§7.5), shape to
  path conversion (§7.3), and cubic flattening (§7.6).
* **stroke.\*** — the outline builder of §8.2.
* **raster.\*** — the sub-scanline scan converter of §8.3, the RGBA canvas and
  its source-over and group-opacity composites, and the PPM writer.
* **render.\*** — the tree walk: property inheritance, transforms, `use`
  resolution, group opacity.
* **main** — `render.txt` parsing and file I/O.

The reference implementation in `reference/main.py` is about 1270 lines of
Python; it is a useful model for the structure.
