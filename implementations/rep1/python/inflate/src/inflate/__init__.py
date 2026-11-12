"""inflate: a pure-Python, table-driven DEFLATE (RFC 1951) decoder.

Public API:

* :func:`inflate` -- decompress a raw DEFLATE stream (``bytes`` -> ``bytes``);
* :class:`InflateError` and its subclasses -- raised for malformed streams.
"""

from .decoder import inflate
from .errors import InflateError, TrailingDataError, TruncatedStreamError

__all__ = ["InflateError", "TrailingDataError", "TruncatedStreamError", "inflate"]
__version__ = "1.0.0"
