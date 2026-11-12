"""Independent facelet-level simulator written straight from the cycle text."""

import re

from rubiks.model import FACELET_CYCLES, FACES, facelet_index

SOLVED = "".join(f * 9 for f in FACES)


def _quarter(face):
    perm = list(range(54))  # perm[b] = a: the sticker at a moves to b
    for cycle in re.findall(r"\(([^)]*)\)", FACELET_CYCLES[face]):
        idx = [facelet_index(n) for n in cycle.split()]
        for a, b in zip(idx, idx[1:] + idx[:1]):
            perm[b] = a
    return perm


QUARTER = {f: _quarter(f) for f in "UDLRFB"}


def apply(state, tokens):
    state = list(state)
    for tok in tokens:
        turns = {"": 1, "2": 2, "'": 3}[tok[1:]]
        for _ in range(turns):
            state = [state[a] for a in QUARTER[tok[0]]]
    return "".join(state)
