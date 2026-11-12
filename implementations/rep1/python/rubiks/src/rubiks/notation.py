"""Parsing and formatting of move sequences in face-turn notation."""

from __future__ import annotations

from collections.abc import Iterable

from .model import MOVE_INDEX, MOVE_NAMES


def parse_moves(text: str) -> list[str]:
    """Split ``text`` into validated move tokens.

    Tokens are separated by whitespace; an empty string is the empty sequence.

    Raises:
        ValueError: if a token is not one of the eighteen moves.
    """
    tokens = text.split()
    for token in tokens:
        if token not in MOVE_INDEX:
            raise ValueError(f"invalid move token: {token!r}")
    return tokens


def format_moves(moves: Iterable[str]) -> str:
    """Join move tokens with single spaces."""
    return " ".join(moves)


def invert_move(move: str) -> str:
    """Inverse of a single move token (``R`` <-> ``R'``, ``R2`` stays)."""
    if move not in MOVE_INDEX:
        raise ValueError(f"invalid move token: {move!r}")
    if move.endswith("2"):
        return move
    return move[0] if move.endswith("'") else move + "'"


def invert_moves(moves: Iterable[str]) -> list[str]:
    """Inverse of a move sequence: reversed order, each move inverted."""
    return [invert_move(m) for m in reversed(list(moves))]


__all__ = ["MOVE_NAMES", "parse_moves", "format_moves", "invert_move", "invert_moves"]
