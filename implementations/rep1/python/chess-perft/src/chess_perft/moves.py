"""Move encoding.

A move is a plain ``int`` packing four fields::

    bits 0-5    origin square
    bits 6-11   destination square
    bits 12-14  promotion piece type (0 = none; KNIGHT..QUEEN otherwise)
    bits 15-17  flag (FLAG_NONE, FLAG_DOUBLE, FLAG_EN_PASSANT, FLAG_CASTLE)

Castling is encoded as the king's two-square move.  The helpers below build,
take apart and format moves.
"""

from __future__ import annotations

from .constants import BISHOP, KNIGHT, PIECE_CHARS, QUEEN, ROOK, parse_square, square_name

FLAG_NONE = 0
FLAG_DOUBLE = 1  # pawn double push
FLAG_EN_PASSANT = 2
FLAG_CASTLE = 3

_PROMO_FROM_CHAR = {"n": KNIGHT, "b": BISHOP, "r": ROOK, "q": QUEEN}


def make_move(origin: int, target: int, promotion: int = 0, flag: int = FLAG_NONE) -> int:
    """Pack a move from its fields."""
    return origin | target << 6 | promotion << 12 | flag << 15


def move_origin(move: int) -> int:
    """Origin square of ``move``."""
    return move & 63


def move_target(move: int) -> int:
    """Destination square of ``move``."""
    return move >> 6 & 63


def move_promotion(move: int) -> int:
    """Promotion piece type of ``move`` (``0`` if it is not a promotion)."""
    return move >> 12 & 7


def move_flag(move: int) -> int:
    """Special-move flag of ``move``."""
    return move >> 15


def move_to_uci(move: int) -> str:
    """Format ``move`` in UCI long algebraic notation (``e2e4``, ``a7a8q``)."""
    promo = move >> 12 & 7
    text = square_name(move & 63) + square_name(move >> 6 & 63)
    return text + PIECE_CHARS[promo] if promo else text


def uci_to_fields(text: str) -> tuple[int, int, int]:
    """Parse UCI text into ``(origin, target, promotion)``."""
    if len(text) not in (4, 5):
        raise ValueError(f"invalid UCI move: {text!r}")
    promo = 0
    if len(text) == 5:
        if text[4] not in _PROMO_FROM_CHAR:
            raise ValueError(f"invalid UCI move: {text!r}")
        promo = _PROMO_FROM_CHAR[text[4]]
    return parse_square(text[:2]), parse_square(text[2:4]), promo
