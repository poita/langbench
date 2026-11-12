"""Constant tables and capacity formulas for QR Code Model 2.

Everything here is derived from ISO/IEC 18004 and is independent of any
particular payload.
"""

from __future__ import annotations

import enum

MIN_VERSION = 1
MAX_VERSION = 40


class ErrorCorrection(enum.Enum):
    """Error correction level.

    ``format_bits`` is the two-bit code stored in the format information and
    ``index`` selects a row of the per-level tables below.
    """

    L = (0, 1)
    M = (1, 0)
    Q = (2, 3)
    H = (3, 2)

    def __init__(self, index: int, format_bits: int) -> None:
        self.index = index
        self.format_bits = format_bits

    @classmethod
    def parse(cls, value: "ErrorCorrection | str") -> "ErrorCorrection":
        """Accept an :class:`ErrorCorrection` or one of ``"L" "M" "Q" "H"``."""
        if isinstance(value, cls):
            return value
        try:
            return cls[str(value).upper()]
        except KeyError:
            raise ValueError(f"invalid error correction level: {value!r}") from None


# ECC codewords per block, indexed [ecl.index][version - 1].
ECC_CODEWORDS_PER_BLOCK = (
    (7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28,
     28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),
    (10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
     26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28),
    (13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30,
     28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),
    (17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28,
     30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),
)

# Number of error correction blocks, indexed [ecl.index][version - 1].
NUM_ERROR_CORRECTION_BLOCKS = (
    (1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8,
     8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25),
    (1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
     17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49),
    (1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20,
     23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68),
    (1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25,
     25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81),
)

# Alignment pattern centre coordinates, indexed by version (index 0 unused).
ALIGNMENT_POSITIONS = (
    (), (),
    (6, 18), (6, 22), (6, 26), (6, 30), (6, 34),
    (6, 22, 38), (6, 24, 42), (6, 26, 46), (6, 28, 50), (6, 30, 54), (6, 32, 58),
    (6, 34, 62),
    (6, 26, 46, 66), (6, 26, 48, 70), (6, 26, 50, 74), (6, 30, 54, 78),
    (6, 30, 56, 82), (6, 30, 58, 86), (6, 34, 62, 90),
    (6, 28, 50, 72, 94), (6, 26, 50, 74, 98), (6, 30, 54, 78, 102),
    (6, 28, 54, 80, 106), (6, 32, 58, 84, 110), (6, 30, 58, 86, 114),
    (6, 34, 62, 90, 118),
    (6, 26, 50, 74, 98, 122), (6, 30, 54, 78, 102, 126), (6, 26, 52, 78, 104, 130),
    (6, 30, 56, 82, 108, 134), (6, 34, 60, 86, 112, 138), (6, 30, 58, 86, 114, 142),
    (6, 34, 62, 90, 118, 146),
    (6, 30, 54, 78, 102, 126, 150), (6, 24, 50, 76, 102, 128, 154),
    (6, 28, 54, 80, 106, 132, 158), (6, 32, 58, 84, 110, 136, 162),
    (6, 26, 54, 82, 110, 138, 166), (6, 30, 58, 86, 114, 142, 170),
)


def check_version(version: int) -> None:
    if not MIN_VERSION <= version <= MAX_VERSION:
        raise ValueError(f"version out of range: {version}")


def symbol_size(version: int) -> int:
    """Side length in modules of a version's symbol."""
    return 4 * version + 17


def raw_modules(version: int) -> int:
    """Number of modules available for codeword bits (before remainder bits)."""
    check_version(version)
    raw = (16 * version + 128) * version + 64
    if version >= 2:
        a = version // 7 + 2
        raw -= (25 * a - 10) * a - 55
        if version >= 7:
            raw -= 36
    return raw


def total_codewords(version: int) -> int:
    """Data plus error correction codewords in a version."""
    return raw_modules(version) // 8


def data_codewords(version: int, ecl: ErrorCorrection) -> int:
    """Number of data codewords at a version and error correction level."""
    check_version(version)
    return (
        total_codewords(version)
        - ECC_CODEWORDS_PER_BLOCK[ecl.index][version - 1]
        * NUM_ERROR_CORRECTION_BLOCKS[ecl.index][version - 1]
    )
