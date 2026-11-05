/**
 * svgraster: a small SVG 1.1 subset rasteriser.
 *
 * Importing `svgraster` gives the whole public API:
 *
 * $(UL
 *   $(LI `svgraster.xml`    - tiny XML reader producing an element tree)
 *   $(LI `svgraster.parse`  - numbers, lengths, colours, transforms, style)
 *   $(LI `svgraster.colors` - the 147 SVG colour keywords)
 *   $(LI `svgraster.geom`   - points and affine matrices)
 *   $(LI `svgraster.path`   - path model, path data, arcs, flattening)
 *   $(LI `svgraster.shapes` - basic shapes as paths)
 *   $(LI `svgraster.stroke` - stroke outlining)
 *   $(LI `svgraster.raster` - canvas and anti-aliasing scan converter)
 *   $(LI `svgraster.render` - the document walk and `renderSvg`)
 *   $(LI `svgraster.batch`  - `render.txt` job lists and directory rendering)
 * )
 *
 * Example:
 * ---
 * import svgraster;
 * auto img = renderSvg(`<svg viewBox="0 0 8 4"><rect x="1" y="1" width="3.5" height="2" fill="#00f"/></svg>`, 8, 4);
 * ubyte[] ppm = img.toPpm();
 * ---
 */
module svgraster;

public import svgraster.batch;
public import svgraster.buf;
public import svgraster.colors;
public import svgraster.geom;
public import svgraster.parse;
public import svgraster.path;
public import svgraster.raster;
public import svgraster.render;
public import svgraster.shapes;
public import svgraster.stroke;
public import svgraster.xml;
