#!/usr/bin/env python3
"""Verifier for the `rubiks` problem.

Usage: verify.py <input.in> <actual.out> [<expected.out>]

Applies each scramble and the corresponding solution line to a facelet
model of the cube and accepts only if the cube ends up solved, the line uses
only the eighteen legal tokens separated by single spaces, and the solution
has at most MAX_MOVES tokens. The expected output is not needed: any valid
solution is accepted. Exit 0 on pass; otherwise print a reason and exit 1.
"""
import re
import sys

MAX_MOVES = 52
FACES = "URFDLB"

# Basic moves as facelet 4-cycles "(a b c d)": the sticker at a moves to b.
CYCLES = {
    "U": "(U1 U3 U9 U7)(U2 U6 U8 U4)(F1 L1 B1 R1)(F2 L2 B2 R2)(F3 L3 B3 R3)",
    "D": "(D1 D3 D9 D7)(D2 D6 D8 D4)(F7 R7 B7 L7)(F8 R8 B8 L8)(F9 R9 B9 L9)",
    "R": "(R1 R3 R9 R7)(R2 R6 R8 R4)(F3 U3 B7 D3)(F6 U6 B4 D6)(F9 U9 B1 D9)",
    "L": "(L1 L3 L9 L7)(L2 L6 L8 L4)(F1 D1 B9 U1)(F4 D4 B6 U4)(F7 D7 B3 U7)",
    "F": "(F1 F3 F9 F7)(F2 F6 F8 F4)(U7 R1 D3 L9)(U8 R4 D2 L6)(U9 R7 D1 L3)",
    "B": "(B1 B3 B9 B7)(B2 B6 B8 B4)(U3 L1 D7 R9)(U2 L4 D8 R6)(U1 L7 D9 R3)",
}


def facelet_index(name):
    return FACES.index(name[0]) * 9 + int(name[1]) - 1


def perm_from_cycles(text):
    """Source table: after the move, position i holds the sticker from src[i]."""
    src = list(range(54))
    for cycle in re.findall(r"\(([^)]*)\)", text):
        idx = [facelet_index(n) for n in cycle.split()]
        for a, b in zip(idx, idx[1:] + idx[:1]):
            src[b] = a
    return src


def compose(p, q):
    """Source table for "apply p, then q"."""
    return [p[q[i]] for i in range(54)]


MOVES = {}
for face, text in CYCLES.items():
    one = perm_from_cycles(text)
    two = compose(one, one)
    MOVES[face] = one
    MOVES[face + "2"] = two
    MOVES[face + "'"] = compose(two, one)

SOLVED = "".join(c * 9 for c in FACES)


def apply_moves(state, tokens):
    for tok in tokens:
        src = MOVES[tok]
        state = "".join(state[src[i]] for i in range(54))
    return state


def fail(msg):
    print(msg)
    sys.exit(1)


def main():
    in_path, actual_path = sys.argv[1], sys.argv[2]

    with open(in_path, encoding="utf-8") as f:
        text = f.read()
    scrambles = text.split("\n")
    if scrambles and scrambles[-1] == "":
        scrambles.pop()

    with open(actual_path, encoding="utf-8", errors="replace") as f:
        out = f.read().replace("\r\n", "\n")
    lines = out.split("\n")
    while lines and lines[-1].strip() == "":
        lines.pop()
    if len(lines) > len(scrambles):
        fail(f"expected {len(scrambles)} output lines, got {len(lines)}")
    # Missing trailing lines can only be empty solutions; padding keeps the
    # check for those scrambles (they must already be solved).
    lines += [""] * (len(scrambles) - len(lines))

    for i, (scr, line) in enumerate(zip(scrambles, lines), 1):
        line = line.rstrip()
        if line == "":
            tokens = []
        else:
            if line != line.lstrip():
                fail(f"line {i}: leading whitespace")
            if "  " in line or "\t" in line:
                fail(f"line {i}: tokens must be separated by exactly one space")
            tokens = line.split(" ")
            for t in tokens:
                if t not in MOVES:
                    fail(f"line {i}: invalid token {t!r}")
        if len(tokens) > MAX_MOVES:
            fail(f"line {i}: solution has {len(tokens)} moves, limit is {MAX_MOVES}")
        state = apply_moves(SOLVED, scr.split())
        state = apply_moves(state, tokens)
        if state != SOLVED:
            fail(f"line {i}: cube not solved after applying solution")
    sys.exit(0)


if __name__ == "__main__":
    main()
