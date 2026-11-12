"""Perft and divide on top of the legal move generator."""

from __future__ import annotations

from .moves import move_to_uci
from .movegen import count_legal_moves, generate_legal_moves
from .position import Position


def perft(position: Position, depth: int) -> int:
    """Count the leaf nodes reached by playing every legal line ``depth`` plies deep.

    ``perft(p, 0) == 1``.  At the last ply moves are counted, not played.
    ``position`` is changed during the search but restored before returning.
    """
    if depth < 0:
        raise ValueError("depth must be non-negative")
    if depth == 0:
        return 1
    if depth == 1:
        return count_legal_moves(position)
    return _search(position, depth)


def _search(pos: Position, depth: int) -> int:
    make = pos.make
    unmake = pos.unmake
    total = 0
    if depth == 2:
        for move in generate_legal_moves(pos):
            undo = make(move)
            total += count_legal_moves(pos)
            unmake(move, undo)
        return total
    depth -= 1
    for move in generate_legal_moves(pos):
        undo = make(move)
        total += _search(pos, depth)
        unmake(move, undo)
    return total


def divide(position: Position, depth: int) -> list[tuple[str, int]]:
    """Return ``(uci_move, perft(depth - 1))`` for every legal move, sorted by move text.

    ``depth`` must be at least 1; the counts sum to ``perft(position, depth)``.
    """
    if depth < 1:
        raise ValueError("divide depth must be at least 1")
    results = []
    for move in generate_legal_moves(position):
        undo = position.make(move)
        count = perft(position, depth - 1)
        position.unmake(move, undo)
        results.append((move_to_uci(move), count))
    results.sort()
    return results
