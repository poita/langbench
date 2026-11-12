"""Differential fuzzing of the VM against the recursive spec oracle."""

import random

import btregex
from oracle import oracle_search


def gen_regex(rng, depth=0):
    def atom():
        r = rng.random()
        if depth < 3 and r < 0.25:
            return "(" + gen_regex(rng, depth + 1) + ")"
        if r < 0.65:
            return rng.choice("abc")
        if r < 0.75:
            return "."
        if r < 0.82:
            return rng.choice(["[ab]", "[^a]", r"\w", r"[a-b]", r"\d"])
        if r < 0.86:
            return "^"
        if r < 0.90:
            return "$"
        return rng.choice("abc")

    def piece():
        a = atom()
        if a in ("^", "$"):
            return a
        r = rng.random()
        if r < 0.45:
            return a
        if r < 0.6:
            return a + "*"
        if r < 0.7:
            return a + "+"
        if r < 0.8:
            return a + "?"
        lo = rng.randint(0, 3)
        form = rng.random()
        if form < 0.3:
            return a + "{%d}" % lo
        if form < 0.5:
            return a + "{%d,}" % lo
        return a + "{%d,%d}" % (lo, lo + rng.randint(0, 2))

    branches = []
    for _ in range(rng.choice([1, 1, 1, 2, 3])):
        branches.append("".join(piece() for _ in range(rng.randint(0, 4))))
    return "|".join(branches)


def test_vm_matches_oracle():
    rng = random.Random(12345)
    for _ in range(1500):
        pattern = gen_regex(rng)
        compiled = btregex.compile(pattern)
        for _ in range(6):
            subject = "".join(rng.choice("abc1") for _ in range(rng.randint(0, 7)))
            expected = oracle_search(pattern, subject)
            got = compiled.search(subject)
            if expected is None:
                assert got is None, (pattern, subject)
            else:
                assert got is not None, (pattern, subject)
                assert (got.span(), got.groups) == expected, (pattern, subject)
