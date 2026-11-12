"""spreadsheet: an in-memory spreadsheet engine with incremental recalculation.

Public API::

    from spreadsheet import Sheet

    sheet = Sheet()
    sheet.set("A1", "10")
    sheet.set("A2", "=A1*2")
    sheet.get("A2")      # "20"
    sheet.dump()         # [("A1", "10"), ("A2", "20")]
"""

from .cli import run_commands
from .formatting import format_number
from .sheet import Sheet
from .values import CYCLE, DIV0, REF, VALUE, CellError

__all__ = [
    "Sheet",
    "run_commands",
    "format_number",
    "CellError",
    "DIV0",
    "REF",
    "CYCLE",
    "VALUE",
]
__version__ = "1.0.0"
