"""myersdiff: exact line diff (Myers, linear space) and patch.

Public API::

    diff(a, b)            -> list[Edit]   minimal edit script
    patch(a, script)      -> list[str]    apply a script
    format_script(script) -> str          "K\\n" + one line per edit
    parse_script_lines(l) -> list[Edit]
    cost(script)          -> int
"""

from .myers import diff
from .patch import PatchError, patch
from .script import (
    DELETE,
    INSERT,
    KEEP,
    Edit,
    cost,
    format_script,
    new_lines,
    old_lines,
    parse_script_lines,
)

__all__ = [
    "DELETE", "INSERT", "KEEP", "Edit", "PatchError", "cost", "diff",
    "format_script", "new_lines", "old_lines", "parse_script_lines", "patch",
]
__version__ = "0.1.0"
