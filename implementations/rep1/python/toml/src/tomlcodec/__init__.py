"""tomlcodec -- a from-scratch TOML 1.0.0 parser and canonical serializer.

Public API:

* :func:`loads` -- parse a TOML document (``bytes`` or ``str``) into a tree;
* :func:`dumps` -- write a tree as canonical TOML;
* :func:`to_tagged_json` / :func:`from_tagged_json` -- the ``toml-test``
  tagged-JSON interchange format;
* :func:`to_python` -- convert a tree to plain Python objects;
* :class:`Table`, :class:`Scalar`, :class:`ArrayOfTables` -- the tree nodes;
* :class:`TomlError`, :class:`TomlDecodeError`, :class:`TaggedJSONError`.
"""

from .convert import to_python
from .encoder import dumps
from .errors import TaggedJSONError, TomlDecodeError, TomlError
from .model import ArrayOfTables, Scalar, Table
from .parser import loads
from .tagged import from_tagged_json, to_tagged_json

__version__ = "1.0.0"

__all__ = [
    "ArrayOfTables",
    "Scalar",
    "TaggedJSONError",
    "Table",
    "TomlDecodeError",
    "TomlError",
    "__version__",
    "dumps",
    "from_tagged_json",
    "loads",
    "to_python",
    "to_tagged_json",
]
