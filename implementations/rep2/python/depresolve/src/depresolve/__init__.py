"""depresolve: a deterministic package dependency resolver.

Typical use::

    from depresolve import parse_input, resolve, format_resolution

    registry, root = parse_input(text)
    print(format_resolution(resolve(registry, root)), end="")
"""

from .ranges import Range, parse_range
from .registry import Registry, Requirement, parse_input, parse_requirements
from .resolver import format_resolution, resolve
from .version import Version

__all__ = [
    "Range",
    "Registry",
    "Requirement",
    "Version",
    "format_resolution",
    "parse_input",
    "parse_range",
    "parse_requirements",
    "resolve",
]
