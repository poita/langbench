"""Shared constants: colours, piece types, castling bits and board masks.

Squares are numbered ``0..63`` with ``a1 = 0``, ``b1 = 1`` ... ``h1 = 7``,
``a2 = 8`` ... ``h8 = 63`` (``square = rank * 8 + file``, both zero-based).
A bitboard is a Python ``int`` in which bit ``s`` stands for square ``s``.
"""

WHITE = 0
BLACK = 1

PAWN, KNIGHT, BISHOP, ROOK, QUEEN, KING = range(6)
EMPTY = -1  # value stored in Position.board for an empty square

PIECE_CHARS = "pnbrqk"  # lowercase letters indexed by piece type

# Castling right bits (Position.castling is an OR of these).
CASTLE_WK = 1
CASTLE_WQ = 2
CASTLE_BK = 4
CASTLE_BQ = 8

NO_EP = -1  # value of Position.ep when there is no en passant square

FULL = (1 << 64) - 1

FILE_A = 0x0101010101010101
FILE_H = FILE_A << 7
NOT_FILE_A = FULL ^ FILE_A
NOT_FILE_H = FULL ^ FILE_H

RANK_1 = 0xFF
RANK_2 = RANK_1 << 8
RANK_3 = RANK_1 << 16
RANK_6 = RANK_1 << 40
RANK_7 = RANK_1 << 48
RANK_8 = RANK_1 << 56


def square_name(square: int) -> str:
    """Return the algebraic name (``"e4"``) of a square index."""
    return "abcdefgh"[square & 7] + "12345678"[square >> 3]


def parse_square(name: str) -> int:
    """Return the square index of an algebraic name such as ``"e4"``."""
    if len(name) != 2 or name[0] not in "abcdefgh" or name[1] not in "12345678":
        raise ValueError(f"invalid square: {name!r}")
    return "12345678".index(name[1]) * 8 + "abcdefgh".index(name[0])
