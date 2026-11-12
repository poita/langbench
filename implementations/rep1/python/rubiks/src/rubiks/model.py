"""Static description of the cube: facelets, cubie slots and the 18 moves.

Everything here is *derived* from the facelet definitions in the problem
statement (the unfolded net, the corner/edge facelet groups and the 4-cycles
of each clockwise quarter turn).  The cubie-level move tables used by the rest
of the library are computed from those cycles at import time, so there is a
single source of truth and no hand-typed permutation tables to get wrong.

Conventions
-----------
* Facelet ``i`` of face ``f`` (``U R F D L B`` order, 1-9 in reading order) has
  flat index ``9 * FACES.index(f) + i - 1``.
* Corner slots are numbered ``0..7`` and edge slots ``0..11`` in the order of
  :data:`CORNER_FACELETS` / :data:`EDGE_FACELETS`; a *piece* is named after the
  slot it occupies in the solved cube.
* The *orientation* of a piece in a slot is the index (within the slot's
  facelet tuple) of the facelet showing the piece's first sticker.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

FACES = "URFDLB"

#: Cycles of each clockwise quarter turn: the sticker at ``a`` moves to ``b``.
FACELET_CYCLES: dict[str, str] = {
    "U": "(U1 U3 U9 U7)(U2 U6 U8 U4)(F1 L1 B1 R1)(F2 L2 B2 R2)(F3 L3 B3 R3)",
    "D": "(D1 D3 D9 D7)(D2 D6 D8 D4)(F7 R7 B7 L7)(F8 R8 B8 L8)(F9 R9 B9 L9)",
    "R": "(R1 R3 R9 R7)(R2 R6 R8 R4)(F3 U3 B7 D3)(F6 U6 B4 D6)(F9 U9 B1 D9)",
    "L": "(L1 L3 L9 L7)(L2 L6 L8 L4)(F1 D1 B9 U1)(F4 D4 B6 U4)(F7 D7 B3 U7)",
    "F": "(F1 F3 F9 F7)(F2 F6 F8 F4)(U7 R1 D3 L9)(U8 R4 D2 L6)(U9 R7 D1 L3)",
    "B": "(B1 B3 B9 B7)(B2 B6 B8 B4)(U3 L1 D7 R9)(U2 L4 D8 R6)(U1 L7 D9 R3)",
}

_CORNER_TEXT = ("U9 R1 F3", "U7 F1 L3", "U1 L1 B3", "U3 B1 R3",
                "D3 F9 R7", "D1 L9 F7", "D7 B9 L7", "D9 R9 B7")
_EDGE_TEXT = ("U6 R2", "U8 F2", "U4 L2", "U2 B2", "D6 R8", "D2 F8",
              "D4 L8", "D8 B8", "F6 R4", "F4 L6", "B6 L4", "B4 R6")


def facelet_index(name: str) -> int:
    """Flat index (0-53) of a facelet name such as ``"U9"``."""
    return FACES.index(name[0]) * 9 + int(name[1]) - 1


#: Facelet indices of each corner slot (URF, UFL, ULB, UBR, DFR, DLF, DBL, DRB).
CORNER_FACELETS = tuple(tuple(facelet_index(n) for n in t.split()) for t in _CORNER_TEXT)
#: Facelet indices of each edge slot (UR UF UL UB DR DF DL DB FR FL BL BR).
EDGE_FACELETS = tuple(tuple(facelet_index(n) for n in t.split()) for t in _EDGE_TEXT)

#: The six faces in move-name order, and the eighteen move names.
MOVE_FACES = "UDLRFB"
MOVE_NAMES: tuple[str, ...] = tuple(f + s for f in MOVE_FACES for s in ("", "'", "2"))
MOVE_INDEX: dict[str, int] = {name: i for i, name in enumerate(MOVE_NAMES)}


def _quarter_turn(face: str) -> list[int]:
    """Facelet destination table of a clockwise quarter turn (``dst[a] = b``)."""
    dst = list(range(54))
    for cycle in re.findall(r"\(([^)]*)\)", FACELET_CYCLES[face]):
        idx = [facelet_index(n) for n in cycle.split()]
        for a, b in zip(idx, idx[1:] + idx[:1]):
            dst[a] = b
    return dst


@dataclass(frozen=True)
class Move:
    """One of the eighteen face turns, as a permutation of cubie slots.

    After the move, corner slot ``j`` holds the piece that was in corner slot
    ``corner_src[j]`` with its orientation increased by ``corner_twist[j]``
    (mod 3); edges likewise with ``edge_src`` / ``edge_flip`` (mod 2).
    """

    name: str
    facelet_dst: tuple[int, ...]
    corner_src: tuple[int, ...]
    corner_twist: tuple[int, ...]
    edge_src: tuple[int, ...]
    edge_flip: tuple[int, ...]


def _cubie_move(name: str, dst: list[int]) -> Move:
    slot_of = {}
    for kind, table in ((3, CORNER_FACELETS), (2, EDGE_FACELETS)):
        for slot, facelets in enumerate(table):
            for k, f in enumerate(facelets):
                slot_of[(kind, f)] = (slot, k)
    out = []
    for kind, table in ((3, CORNER_FACELETS), (2, EDGE_FACELETS)):
        src = [0] * len(table)
        delta = [0] * len(table)
        for i, facelets in enumerate(table):
            shifts = set()
            for k, f in enumerate(facelets):
                j, k2 = slot_of[(kind, dst[f])]
                src[j] = i
                shifts.add((k2 - k) % kind)
            if len(shifts) != 1:  # pragma: no cover - would mean a bad definition
                raise AssertionError("inconsistent cubie twist in " + name)
            delta[j] = shifts.pop()
        out += [tuple(src), tuple(delta)]
    return Move(name, tuple(dst), *out)


def _build_moves() -> tuple[Move, ...]:
    moves = []
    for face in MOVE_FACES:
        q = _quarter_turn(face)
        inv = [0] * 54
        for a, b in enumerate(q):
            inv[b] = a
        half = [q[q[a]] for a in range(54)]
        for suffix, dst in (("", q), ("'", inv), ("2", half)):
            moves.append(_cubie_move(face + suffix, dst))
    return tuple(moves)


#: The eighteen moves, indexed consistently with :data:`MOVE_NAMES`.
MOVES: tuple[Move, ...] = _build_moves()

#: Slot lists of the three edge slices (positions, which equal piece ids).
M_SLICE = (1, 3, 5, 7)   # UF UB DF DB
S_SLICE = (0, 2, 4, 6)   # UR UL DR DL
E_SLICE = (8, 9, 10, 11)  # FR FL BL BR
