"""Function patterns and the zigzag data-module walk.

Symbols are held as lists of integer rows. Within a row, the module at column
``x`` is bit ``n - 1 - x`` so that ``format(row, "0{n}b")`` reads left to right.
"""

from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache

from .tables import ALIGNMENT_POSITIONS, symbol_size, check_version


@dataclass(frozen=True)
class Layout:
    """Version-specific, payload-independent structure of a symbol.

    ``dark``: rows holding the dark function modules (format area left light).
    ``function``: rows with a 1 at every function module.
    ``order``: ``(y, shift)`` of every data module in placement order, where
    ``shift`` is the bit index of the module inside the row integer.
    """

    version: int
    size: int
    dark: tuple[int, ...]
    function: tuple[int, ...]
    order: tuple[tuple[int, int], ...]


def version_bits(version: int) -> int:
    """18-bit version information (BCH(18,6)) for ``version >= 7``."""
    rem = version
    for _ in range(12):
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
    return (version << 12) | rem


def format_bits(ecl_bits: int, mask: int) -> int:
    """15-bit format information for an error level code and mask number."""
    data = (ecl_bits << 3) | mask
    rem = data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    return ((data << 10) | rem) ^ 0x5412


def format_positions(size: int) -> list[tuple[int, int, int]]:
    """``(x, y, bit_index)`` for both copies of the format information."""
    n = size
    pos = []
    for i in range(6):
        pos.append((8, i, i))
    pos.append((8, 7, 6))
    pos.append((8, 8, 7))
    pos.append((7, 8, 8))
    for i in range(9, 15):
        pos.append((14 - i, 8, i))
    for i in range(8):
        pos.append((n - 1 - i, 8, i))
    for i in range(8, 15):
        pos.append((8, n - 15 + i, i))
    return pos


@lru_cache(maxsize=None)
def layout_for(version: int) -> Layout:
    """Draw (and cache) the function patterns of ``version``."""
    check_version(version)
    n = symbol_size(version)
    dark = [[0] * n for _ in range(n)]
    func = [[0] * n for _ in range(n)]

    def put(x: int, y: int, d: int) -> None:
        dark[y][x] = d
        func[y][x] = 1

    # Finder patterns with separators.
    for cx, cy in ((3, 3), (n - 4, 3), (3, n - 4)):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                x, y = cx + dx, cy + dy
                if 0 <= x < n and 0 <= y < n:
                    put(x, y, 1 if max(abs(dx), abs(dy)) in (0, 1, 3) else 0)
    # Timing patterns.
    for i in range(8, n - 8):
        put(i, 6, 1 - i % 2)
        put(6, i, 1 - i % 2)
    # Alignment patterns.
    pos = ALIGNMENT_POSITIONS[version]
    if pos:
        first, last = pos[0], pos[-1]
        for py in pos:
            for px in pos:
                if (px, py) in ((first, first), (last, first), (first, last)):
                    continue
                for dy in range(-2, 3):
                    for dx in range(-2, 3):
                        put(px + dx, py + dy, 0 if max(abs(dx), abs(dy)) == 1 else 1)
    # Dark module and reserved format areas.
    put(8, n - 8, 1)
    for x, y, _ in format_positions(n):
        put(x, y, 0)
    # Version information.
    if version >= 7:
        bits = version_bits(version)
        for i in range(18):
            d = (bits >> i) & 1
            put(n - 11 + i % 3, i // 3, d)
            put(i // 3, n - 11 + i % 3, d)

    # Zigzag data module order.
    order = []
    right = n - 1
    while right >= 1:
        if right == 6:
            right = 5
        upward = ((right + 1) & 2) == 0
        rows = range(n - 1, -1, -1) if upward else range(n)
        for y in rows:
            for x in (right, right - 1):
                if not func[y][x]:
                    order.append((y, n - 1 - x))
        right -= 2

    def pack(grid: list[list[int]]) -> tuple[int, ...]:
        return tuple(int("".join(map(str, row)), 2) for row in grid)

    return Layout(version, n, pack(dark), pack(func), tuple(order))


def place_codewords(layout: Layout, codewords: bytes) -> list[int]:
    """Rows containing the codeword bits at their data modules (unmasked)."""
    rows = [0] * layout.size
    nbits = 8 * len(codewords)
    value = int.from_bytes(codewords, "big")
    order = layout.order
    for i in range(nbits):
        if (value >> (nbits - 1 - i)) & 1:
            y, shift = order[i]
            rows[y] |= 1 << shift
    return rows
