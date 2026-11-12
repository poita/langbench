"""sitegen: a static site generator.

The public API:

* :func:`generate` builds a site from a source directory into an output
  directory (what the command-line tool does);
* :func:`read_source`, :func:`build_model` and :func:`render_pages` expose
  the stages of that pipeline;
* :mod:`sitegen.markdown`, :mod:`sitegen.template` and :mod:`sitegen.toml`
  are standalone engines that can be used on their own.
"""

from __future__ import annotations

from .errors import ContentError, SitegenError, TomlError
from .generator import generate, render_pages
from .model import SiteModel, build_model
from .source import Source, read_source

__version__ = "1.0.0"

__all__ = [
    "ContentError", "SitegenError", "TomlError", "SiteModel", "Source",
    "build_model", "generate", "read_source", "render_pages",
]
