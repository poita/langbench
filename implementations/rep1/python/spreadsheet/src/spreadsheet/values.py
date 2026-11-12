"""Value types shared by the parser, evaluator and sheet.

A cell value is one of:

* ``float``      -- a finite number,
* ``str``        -- a string,
* ``CellError``  -- one of the four error values below,
* ``None``       -- *empty* (a reference to a cell that holds nothing).
"""

from __future__ import annotations

from dataclasses import dataclass

__all__ = [
    "CellError",
    "DIV0",
    "REF",
    "CYCLE",
    "VALUE",
    "Value",
    "display",
]


@dataclass(frozen=True, slots=True)
class CellError:
    """An error value; ``code`` is its displayed form, e.g. ``#DIV/0!``."""

    code: str

    def __str__(self) -> str:
        return self.code


DIV0 = CellError("#DIV/0!")
REF = CellError("#REF!")
CYCLE = CellError("#CYCLE!")
VALUE = CellError("#VALUE!")

Value = float | str | CellError | None


def display(value: Value) -> str:
    """Return the displayed form of *value* (empty string for empty)."""
    from .formatting import format_number

    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, CellError):
        return value.code
    return format_number(value)
