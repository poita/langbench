"""svgraster: a small pure-Python rasteriser for a subset of SVG 1.1.

Public API::

    from svgraster import render_svg, render_to_ppm

    rgb = render_svg(svg_text, 64, 64)       # packed RGB bytes, rows top to bottom
    ppm = render_to_ppm(svg_text, 64, 64)    # a complete binary PPM (P6) file
"""

from .batch import parse_render_list, render_directory
from .raster import Canvas
from .render import render_svg, render_to_canvas, render_to_ppm

__all__ = [
    "Canvas",
    "parse_render_list",
    "render_directory",
    "render_svg",
    "render_to_canvas",
    "render_to_ppm",
]
__version__ = "1.0.0"
