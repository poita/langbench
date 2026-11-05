#!/usr/bin/env python3
"""Reference solver for the `rubiks` problem: Thistlethwaite's four-phase
algorithm on a cubie-level cube model.

Each phase reduces the cube into a smaller subgroup using a restricted move
set, and a bidirectional breadth-first search on a phase-specific invariant
finds a shortest phase solution:

  phase 1  <U,D,L,R,F,B>       -> G1 = <U,D,L,R,F2,B2>   edge orientation
  phase 2  <U,D,L,R,F2,B2>     -> G2 = <U,D,L2,R2,F2,B2> corner orientation,
                                                         E-slice edges home
  phase 3  <U,D,L2,R2,F2,B2>   -> G3 = <U2,D2,L2,R2,F2,B2> corners in the
                                                         half-turn coset,
                                                         edges in their slices
  phase 4  <U2,D2,L2,R2,F2,B2> -> solved

Because every phase search is breadth-first and therefore optimal within the
phase, the total length never exceeds 7 + 10 + 13 + 15 = 45 half-turn-metric
moves. The search from the solved side is shared across scrambles.
"""
import itertools
import sys

# Cubie positions. Corners: URF UFL ULB UBR DFR DLF DBL DRB.
# Edges: UR UF UL UB DR DF DL DB FR FL BL BR.
URF, UFL, ULB, UBR, DFR, DLF, DBL, DRB = range(8)
UR, UF, UL, UB, DR, DF, DL, DB, FR, FL, BL, BR = range(12)

# Each basic move as: (corner permutation, corner orientation delta,
# edge permutation, edge orientation delta). The permutation entry at index i
# names the cubie that arrives at position i when the move is applied to a
# solved cube; orientation deltas are added modulo 3 (corners) or 2 (edges).
BASIC = {
    "U": ([UBR, URF, UFL, ULB, DFR, DLF, DBL, DRB], [0] * 8,
          [UB, UR, UF, UL, DR, DF, DL, DB, FR, FL, BL, BR], [0] * 12),
    "R": ([DFR, UFL, ULB, URF, DRB, DLF, DBL, UBR], [2, 0, 0, 1, 1, 0, 0, 2],
          [FR, UF, UL, UB, BR, DF, DL, DB, DR, FL, BL, UR], [0] * 12),
    "F": ([UFL, DLF, ULB, UBR, URF, DFR, DBL, DRB], [1, 2, 0, 0, 2, 1, 0, 0],
          [UR, FL, UL, UB, DR, FR, DL, DB, UF, DF, BL, BR],
          [0, 1, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0]),
    "D": ([URF, UFL, ULB, UBR, DLF, DBL, DRB, DFR], [0] * 8,
          [UR, UF, UL, UB, DF, DL, DB, DR, FR, FL, BL, BR], [0] * 12),
    "L": ([URF, ULB, DBL, UBR, DFR, UFL, DLF, DRB], [0, 1, 2, 0, 0, 2, 1, 0],
          [UR, UF, BL, UB, DR, DF, FL, DB, FR, UL, DL, BR], [0] * 12),
    "B": ([URF, UFL, UBR, DRB, DFR, DLF, ULB, DBL], [0, 0, 1, 2, 0, 0, 2, 1],
          [UR, UF, UL, BR, DR, DF, DL, BL, FR, FL, UB, DB],
          [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 1]),
}

# A cube state is a 40-tuple: cp[0:8], co[8:16], ep[16:28], eo[28:40].
SOLVED = tuple(range(8)) + (0,) * 8 + tuple(range(12)) + (0,) * 12


def compose(a, b):
    """State reached by applying move-state b after state a."""
    cp = tuple(a[b[i]] for i in range(8))
    co = tuple((a[8 + b[i]] + b[8 + i]) % 3 for i in range(8))
    ep = tuple(a[16 + b[16 + i]] for i in range(12))
    eo = tuple((a[28 + b[16 + i]] + b[28 + i]) % 2 for i in range(12))
    return cp + co + ep + eo


MOVES = {}
for face, (cp, co, ep, eo) in BASIC.items():
    one = tuple(cp) + tuple(co) + tuple(ep) + tuple(eo)
    two = compose(one, one)
    MOVES[face] = one
    MOVES[face + "2"] = two
    MOVES[face + "'"] = compose(two, one)

INVERSE = {m: (m[0] if m.endswith("'") else m + "'" if len(m) == 1 else m)
           for m in MOVES}

PHASE_MOVES = [
    [f + s for f in "UDLRFB" for s in ("", "2", "'")],
    [f + s for f in "UDLR" for s in ("", "2", "'")] + ["F2", "B2"],
    [f + s for f in "UD" for s in ("", "2", "'")] + ["L2", "R2", "F2", "B2"],
    [f + "2" for f in "UDLRFB"],
]


def build_corner_cosets():
    """Map every corner permutation to the index of its coset of the corner
    permutation group of the half-turn subgroup G3 (420 cosets of size 96).
    Two states with equal coset index and equal edge slice pattern differ by
    an element of G3, which is exactly what phase 3 needs to reach."""
    gens = [MOVES[m][0:8] for m in PHASE_MOVES[3]]
    coset = {}
    for perm in itertools.permutations(range(8)):
        if perm in coset:
            continue
        idx = len(coset)
        stack = [perm]
        coset[perm] = idx
        while stack:
            p = stack.pop()
            for g in gens:
                q = tuple(g[p[i]] for i in range(8))
                if q not in coset:
                    coset[q] = idx
                    stack.append(q)
    return coset


CORNER_COSET = build_corner_cosets()


def id1(s):
    return s[28:40]


def id2(s):
    mask = 0
    for i in range(12):
        if s[16 + i] >= 8:
            mask |= 1 << i
    return s[8:16] + (mask,)


def id3(s):
    mask = 0
    for i in range(8):
        if s[16 + i] & 1:
            mask |= 1 << i
    return (CORNER_COSET[s[0:8]], mask)


def id4(s):
    return s


IDFN = [id1, id2, id3, id4]


class Backward:
    """Breadth-first search outward from the solved cube with one phase's move
    set, keyed by that phase's invariant. Levels are expanded on demand and
    kept between scrambles."""

    def __init__(self, phase):
        self.idfn = IDFN[phase]
        self.moves = PHASE_MOVES[phase]
        root = self.idfn(SOLVED)
        self.visited = {root: (None, None)}  # id -> (parent id, move)
        self.frontier = [(root, SOLVED)]
        self.depth = 0

    def expand(self):
        nxt = []
        for pid, st in self.frontier:
            for m in self.moves:
                ns = compose(st, MOVES[m])
                nid = self.idfn(ns)
                if nid not in self.visited:
                    self.visited[nid] = (pid, m)
                    nxt.append((nid, ns))
        self.frontier = nxt
        self.depth += 1


BACKWARD = [Backward(p) for p in range(4)]


def solve_phase(state, phase):
    idfn = IDFN[phase]
    moves = PHASE_MOVES[phase]
    bwd = BACKWARD[phase]
    root = idfn(state)
    fwd = {root: (None, None)}
    frontier = [(root, state)]
    meet = root if root in bwd.visited else None
    while meet is None:
        if len(frontier) <= len(bwd.frontier) or not bwd.frontier:
            nxt = []
            for pid, st in frontier:
                for m in moves:
                    ns = compose(st, MOVES[m])
                    nid = idfn(ns)
                    if nid not in fwd:
                        fwd[nid] = (pid, m)
                        nxt.append((nid, ns))
                        if nid in bwd.visited and meet is None:
                            meet = nid
            frontier = nxt
        else:
            bwd.expand()
            for nid, _ in bwd.frontier:
                if nid in fwd:
                    meet = nid
                    break
    path = []
    cur = meet
    while fwd[cur][1] is not None:
        pid, m = fwd[cur]
        path.append(m)
        cur = pid
    path.reverse()
    cur = meet
    while bwd.visited[cur][1] is not None:
        pid, m = bwd.visited[cur]
        path.append(INVERSE[m])
        cur = pid
    return path


QUARTERS = {"": 1, "2": 2, "'": 3}
SUFFIX = {1: "", 2: "2", 3: "'"}


def merge_same_face(moves):
    """Collapse adjacent moves of the same face into one move (or none), so
    that phase boundaries never leave sequences like `R R2` behind. This only
    shortens the solution."""
    out = []
    for m in moves:
        if out and out[-1][0] == m[0]:
            q = (QUARTERS[out[-1][1:]] + QUARTERS[m[1:]]) % 4
            out.pop()
            if q:
                out.append(m[0] + SUFFIX[q])
        else:
            out.append(m)
    return out


def solve(state):
    solution = []
    for phase in range(4):
        moves = solve_phase(state, phase)
        for m in moves:
            state = compose(state, MOVES[m])
        solution.extend(moves)
    assert state == SOLVED
    return merge_same_face(solution)


def main():
    data = sys.stdin.read()
    lines = data.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    out = []
    for line in lines:
        state = SOLVED
        for tok in line.split():
            state = compose(state, MOVES[tok])
        out.append(" ".join(solve(state)))
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
