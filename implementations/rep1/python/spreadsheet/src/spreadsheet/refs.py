"""Cell references: names such as ``B12`` and their packed integer keys.

A cell is identified internally by an integer key ``(row << 10) | column``
with column 1..702 and row 1..9999.  Sorting keys therefore yields row-major
order.
"""

from __future__ import annotations

__all__ = [
    "MAX_COL",
    "MAX_ROW",
    "make_key",
    "key_row",
    "key_col",
    "parse_ref",
    "cell_name",
]

MAX_COL = 702
MAX_ROW = 9999
_COL_BITS = 10
_COL_MASK = (1 << _COL_BITS) - 1


def make_key(row: int, col: int) -> int:
    """Pack a 1-based *row* and *col* into a cell key."""
    return (row << _COL_BITS) | col


def key_row(key: int) -> int:
    return key >> _COL_BITS


def key_col(key: int) -> int:
    return key & _COL_MASK


def parse_ref(text: str) -> int | None:
    """Return the key for cell name *text*, or ``None`` if it is not valid.

    Valid names are one or two uppercase ASCII letters followed by a row
    number 1..9999 without leading zeros.
    """
    i = 0
    n = len(text)
    while i < n and "A" <= text[i] <= "Z":
        i += 1
    if i == 0 or i > 2 or i == n:
        return None
    digits = text[i:]
    if not (digits.isascii() and digits.isdigit()) or digits[0] == "0":
        return None
    row = int(digits)
    if row > MAX_ROW:
        return None
    col = 0
    for ch in text[:i]:
        col = col * 26 + (ord(ch) - 64)
    return make_key(row, col)


def cell_name(key: int) -> str:
    """Return the name (e.g. ``AB7``) of the cell with the given key."""
    col = key_col(key)
    letters = ""
    while col:
        col, rem = divmod(col - 1, 26)
        letters = chr(65 + rem) + letters
    return f"{letters}{key_row(key)}"
