//! # svgraster
//!
//! A small SVG 1.1 subset rasteriser. It parses an SVG document, flattens
//! shapes and strokes to polygons, scan-converts them with 64 sub-scanlines
//! per pixel row (exact `x` spans, so anti-aliased coverage is accurate to
//! 1/64) and writes the result as a binary PPM image over a white
//! background.
//!
//! Everything is implemented from scratch with the standard library only.
//!
//! ```
//! let svg = r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 4">
//!   <rect x="1" y="1" width="3.5" height="2" fill="#0000ff"/>
//! </svg>"##;
//! let canvas = svgraster::render_svg(svg, 8, 4).unwrap();
//! let ppm = canvas.to_ppm();
//! assert!(ppm.starts_with(b"P6\n8 4\n255\n"));
//! ```
//!
//! ## Modules
//!
//! * [`xml`] – minimal XML parser producing an element arena.
//! * [`number`], [`color`], [`transform`], [`style`] – value micro-grammars.
//! * [`path`] – path data, arcs, shapes and curve flattening.
//! * [`stroke`] – stroke outline construction.
//! * [`raster`] – the scan converter.
//! * [`canvas`] – the RGBA canvas, compositing and PPM encoding.
//! * [`render`] – the document walk that ties everything together.
//! * [`jobs`] – `render.txt` parsing and the directory driver.

pub mod canvas;
pub mod color;
pub mod error;
pub mod geom;
pub mod jobs;
pub mod number;
pub mod path;
pub mod raster;
pub mod render;
pub mod stroke;
pub mod style;
pub mod transform;
pub mod xml;

pub use canvas::Canvas;
pub use error::Error;
pub use render::render_svg;
