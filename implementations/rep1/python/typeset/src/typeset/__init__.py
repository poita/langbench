"""typeset -- the Codexa typesetting engine.

Public API::

    from typeset import typeset, typeset_directory, CodexaError

    result = typeset(document_text, settings_text, data_dir="data")
    print(result.layout)   # contents of layout.txt
    print(result.report)   # contents of report.txt

Invalid input raises :class:`CodexaError`, whose ``format()`` is the single
line written to ``error.txt``.
"""

from .engine import Result, typeset, typeset_directory
from .errors import CodexaError
from .settings import Settings, parse_settings
from .parser import parse_document

__all__ = [
    "CodexaError", "Result", "Settings", "parse_document", "parse_settings",
    "typeset", "typeset_directory",
]
__version__ = "1.0.0"
