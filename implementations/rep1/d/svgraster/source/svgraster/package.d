/**
 * svgraster: a small, dependency-free rasteriser for a subset of SVG 1.1.
 *
 * The library parses an SVG document (basic shapes, paths, transforms,
 * `use`, inherited painting properties, group opacity), flattens and strokes
 * the geometry, fills it with 64-sub-scanline anti-aliasing and returns the
 * result as a `Canvas` that can be written as a binary PPM.
 *
 * ---
 * import svgraster;
 *
 * auto canvas = renderSvg(`<svg viewBox="0 0 10 10">
 *     <circle cx="5" cy="5" r="4" fill="tomato"/></svg>`, 64, 64);
 * ubyte[] ppm = canvas.toPpm();
 * ---
 *
 * Modules:
 * $(UL
 *   $(LI `svgraster.xml` – minimal XML reader)
 *   $(LI `svgraster.parse` – numbers, colours, transforms, `style`)
 *   $(LI `svgraster.path`, `svgraster.pathdata`, `svgraster.shapes` – geometry)
 *   $(LI `svgraster.stroke` – stroke outlining)
 *   $(LI `svgraster.raster` – canvas, scan converter, PPM output)
 *   $(LI `svgraster.render` – the document renderer)
 *   $(LI `svgraster.batch` – `render.txt` job lists)
 * )
 */
module svgraster;

public import svgraster.batch;
public import svgraster.colors;
public import svgraster.geom;
public import svgraster.parse;
public import svgraster.path;
public import svgraster.pathdata;
public import svgraster.raster;
public import svgraster.render;
public import svgraster.shapes;
public import svgraster.stroke;
public import svgraster.xml;
