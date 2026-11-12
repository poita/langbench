"""cmarkpy: a dependency-free CommonMark-to-HTML converter.

The converter implements a subset of CommonMark 0.31.2 (no raw HTML and no
link reference definitions) with the same two-phase design and output as the
``cmark`` reference implementation.

>>> from cmarkpy import convert
>>> convert("Hello *world*")
'<p>Hello <em>world</em></p>\\n'
"""

from .api import convert, parse
from .nodes import Node
from .render import render_html

__all__ = ["Node", "convert", "parse", "render_html", "__version__"]
__version__ = "0.1.0"
