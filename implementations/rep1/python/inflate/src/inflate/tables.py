"""Constant tables from RFC 1951."""

from __future__ import annotations

#: Base value of each length symbol 257..285 (index = symbol - 257).
LENGTH_BASE: tuple[int, ...] = (
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
)  # fmt: skip

#: Number of extra bits of each length symbol 257..285.
LENGTH_EXTRA: tuple[int, ...] = (
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
)  # fmt: skip

#: Base value of each distance symbol 0..29.
DIST_BASE: tuple[int, ...] = (
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
    8193, 12289, 16385, 24577,
)  # fmt: skip

#: Number of extra bits of each distance symbol 0..29.
DIST_EXTRA: tuple[int, ...] = (
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
)  # fmt: skip

#: Order in which code-length-code lengths are stored in a dynamic header.
CODE_LENGTH_ORDER: tuple[int, ...] = (
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
)  # fmt: skip

END_OF_BLOCK = 256
MAX_CODE_LENGTH = 15
MAX_LITLEN_SYMBOLS = 286  # HLIT + 257 may be at most this
MAX_DIST_SYMBOLS = 30  # HDIST + 1 may be at most this


def fixed_litlen_lengths() -> list[int]:
    """Code lengths of the fixed literal/length code (288 symbols)."""
    return [8] * 144 + [9] * 112 + [7] * 24 + [8] * 8


def fixed_dist_lengths() -> list[int]:
    """Code lengths of the fixed distance code (32 symbols)."""
    return [5] * 32
