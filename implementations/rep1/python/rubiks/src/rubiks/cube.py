"""Cubie-level cube state."""

from __future__ import annotations

from collections.abc import Iterable

from .model import (CORNER_FACELETS, EDGE_FACELETS, FACES, MOVE_INDEX, MOVES)

_SOLVED_CP = tuple(range(8))
_SOLVED_EP = tuple(range(12))


class Cube:
    """A 3x3x3 cube as permutation + orientation of corner and edge cubies.

    Attributes (indexed by *slot*):
        cp: ``cp[s]`` is the corner piece in corner slot ``s`` (0-7).
        co: ``co[s]`` is its twist (0-2).
        ep: ``ep[s]`` is the edge piece in edge slot ``s`` (0-11).
        eo: ``eo[s]`` is its flip (0-1).

    A new ``Cube()`` is solved.  Moves are applied in place with
    :meth:`apply` / :meth:`apply_moves`; :meth:`copy` clones the state.
    Slot and orientation conventions are documented in :mod:`rubiks.model`.
    """

    __slots__ = ("cp", "co", "ep", "eo")

    def __init__(self, cp=None, co=None, ep=None, eo=None):
        self.cp = list(cp) if cp is not None else list(_SOLVED_CP)
        self.co = list(co) if co is not None else [0] * 8
        self.ep = list(ep) if ep is not None else list(_SOLVED_EP)
        self.eo = list(eo) if eo is not None else [0] * 12

    # -- construction -----------------------------------------------------
    @classmethod
    def from_moves(cls, moves: Iterable[str] | str) -> "Cube":
        """A solved cube with ``moves`` applied (a token list or a string)."""
        cube = cls()
        cube.apply_moves(moves)
        return cube

    def copy(self) -> "Cube":
        return Cube(self.cp, self.co, self.ep, self.eo)

    # -- moves ------------------------------------------------------------
    def apply(self, move: str | int) -> None:
        """Apply one move, given as a token (``"R'"``) or a move index."""
        m = MOVES[MOVE_INDEX[move] if isinstance(move, str) else move]
        cp, co, ep, eo = self.cp, self.co, self.ep, self.eo
        self.cp = [cp[i] for i in m.corner_src]
        self.co = [(co[i] + t) % 3 for i, t in zip(m.corner_src, m.corner_twist)]
        self.ep = [ep[i] for i in m.edge_src]
        self.eo = [eo[i] ^ f for i, f in zip(m.edge_src, m.edge_flip)]

    def apply_moves(self, moves: Iterable[str] | str) -> None:
        """Apply a sequence of moves in order (tokens, or a space-separated string)."""
        if isinstance(moves, str):
            moves = moves.split()
        for move in moves:
            self.apply(move)

    # -- queries ----------------------------------------------------------
    def is_solved(self) -> bool:
        return (self.cp == list(_SOLVED_CP) and self.ep == list(_SOLVED_EP)
                and not any(self.co) and not any(self.eo))

    def to_facelets(self) -> str:
        """The 54 facelet colours as a string, in ``U R F D L B`` face order.

        Each character names the face whose centre has that colour, so the
        solved cube is ``"UUUUUUUUURRRRRRRRRFFFFFFFFFDDDDDDDDDLLLLLLLLLBBBBBBBBB"``.
        """
        out = [""] * 54
        for slot in range(8):
            piece, twist = self.cp[slot], self.co[slot]
            for k, f in enumerate(CORNER_FACELETS[slot]):
                out[f] = FACES[CORNER_FACELETS[piece][(k - twist) % 3] // 9]
        for slot in range(12):
            piece, flip = self.ep[slot], self.eo[slot]
            for k, f in enumerate(EDGE_FACELETS[slot]):
                out[f] = FACES[EDGE_FACELETS[piece][(k - flip) % 2] // 9]
        for face in range(6):
            out[face * 9 + 4] = FACES[face]
        return "".join(out)

    # -- dunder -----------------------------------------------------------
    def __eq__(self, other):
        if not isinstance(other, Cube):
            return NotImplemented
        return (self.cp, self.co, self.ep, self.eo) == (other.cp, other.co, other.ep, other.eo)

    __hash__ = None  # mutable

    def __repr__(self):
        return f"Cube(cp={self.cp}, co={self.co}, ep={self.ep}, eo={self.eo})"
