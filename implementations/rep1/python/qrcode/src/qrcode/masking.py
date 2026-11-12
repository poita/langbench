"""Mask patterns and their application to a symbol."""

from __future__ import annotations

from functools import lru_cache

from .layout import Layout, format_bits, format_positions

NUM_MASKS = 8


def mask_condition(mask: int, x: int, y: int) -> bool:
    """Whether mask ``mask`` inverts the module at column ``x``, row ``y``."""
    if mask == 0:
        return (x + y) % 2 == 0
    if mask == 1:
        return y % 2 == 0
    if mask == 2:
        return x % 3 == 0
    if mask == 3:
        return (x + y) % 3 == 0
    if mask == 4:
        return (x // 3 + y // 2) % 2 == 0
    if mask == 5:
        return (x * y) % 2 + (x * y) % 3 == 0
    if mask == 6:
        return ((x * y) % 2 + (x * y) % 3) % 2 == 0
    if mask == 7:
        return ((x + y) % 2 + (x * y) % 3) % 2 == 0
    raise ValueError(f"invalid mask: {mask}")


# Every pattern repeats every 6 columns and every 12 rows, so a 12 x 6 tile
# (extended to 180 columns) yields any row without per-module work.
_MAX_COLS = 180


@lru_cache(maxsize=None)
def _tile_rows(mask: int) -> tuple[str, ...]:
    rows = []
    for y in range(12):
        period = "".join("1" if mask_condition(mask, x, y) else "0" for x in range(6))
        rows.append(period * (_MAX_COLS // 6))
    return tuple(rows)


@lru_cache(maxsize=None)
def mask_rows(size: int, mask: int) -> tuple[int, ...]:
    """Rows of ``size`` bits with a 1 wherever ``mask`` would invert a module."""
    tile = _tile_rows(mask)
    return tuple(int(tile[y % 12][:size], 2) for y in range(size))


def apply_mask(layout: Layout, data_rows: list[int], ecl_bits: int, mask: int) -> list[int]:
    """Complete symbol (as rows) for ``mask``: masked data, function modules
    and the format information for ``ecl_bits`` / ``mask``."""
    n = layout.size
    pattern = mask_rows(n, mask)
    func = layout.function
    dark = layout.dark
    rows = [
        (d ^ (p & ~f)) | k for d, p, f, k in zip(data_rows, pattern, func, dark)
    ]
    bits = format_bits(ecl_bits, mask)
    for x, y, i in format_positions(n):
        if (bits >> i) & 1:
            rows[y] |= 1 << (n - 1 - x)
    return rows
