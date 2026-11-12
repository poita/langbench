"""depresolve: a deterministic package dependency resolver.

Typical use::

    from depresolve import parse_problem, resolve

    registry, root = parse_problem(text)
    resolution = resolve(registry, root)
    if resolution is None:
        print("unsatisfiable")
    else:
        print("\\n".join(resolution.lines()))
"""

from .model import Registry, Requirement
from .parser import parse_problem, parse_requirements
from .ranges import VersionRange
from .resolver import Resolution, resolve
from .version import Version

__all__ = [
    "Registry",
    "Requirement",
    "Resolution",
    "Version",
    "VersionRange",
    "parse_problem",
    "parse_requirements",
    "resolve",
]
__version__ = "1.0.0"
