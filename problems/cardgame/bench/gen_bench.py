#!/usr/bin/env python3
"""Deterministic generator for the Spiremark (`cardgame`) performance benchmark.

Writes three long self-played match files to this directory, in the same
layout as `tests/` (`NNN_name.in` / `NNN_name.out`), with expected outputs
computed by the reference implementation.  Scripts come from the self-play
driver of `gen_tests.py`, which walks the reference engine's own `LEGAL`
output, so every action line is a realistic, accepted move (apart from the
few deliberately bogus lines mixed in by `error_rate`).

Run it from anywhere:  python3 problems/cardgame/bench/gen_bench.py [name...]
Generation takes a few minutes in all (the Python reference is slow).
"""

import os
import random
import re
import sys

sys.dont_write_bytecode = True
BENCH = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(BENCH))

import gen_tests as G                    # noqa: E402  (chdirs to problem dir)


class BenchPlay(G.SelfPlay):
    """Self-play that issues inspection directives only outside combat, the
    way a person inspects a match between turns rather than mid-clash."""

    def step(self):
        rate = self.directive_rate
        if self.g.cur_phase.startswith("clash"):
            self.directive_rate = 0.0
        try:
            return super().step()
        finally:
            self.directive_rate = rate


def card_blocks():
    text = open(G.DB, encoding="utf-8").read()
    out = {}
    for b in re.split(r"\n(?=\(card )", text):
        m = re.match(r"\(card (\S+)", b)
        if m and not m.group(1).startswith("TOK"):
            out[m.group(1)] = b
    return out


def deck(rng, sub, n):
    counts = {}
    for _ in range(n):
        c = rng.choice(sub)
        counts[c] = counts.get(c, 0) + 1
    return ["%s*%d" % (c, k) if k > 1 else c for c, k in sorted(counts.items())]


def long_match(lines=45000, spire=400000, deck_n=8000):
    """Two full-pool decks, huge Spire: hundreds of turns of ordinary play."""
    rng = random.Random(74001)
    pool = G.card_pool()
    setup = G.S(seed=74001, spire=spire, opening=5, shuffle="on",
                turnlimit=100000,
                deck_a=deck(rng, pool, deck_n), deck_b=deck(rng, pool, deck_n))
    sp = BenchPlay(setup, 74002, act_bias=0.75, attack_bias=0.55,
                    block_bias=0.5, directive_rate=0.0004, error_rate=0.002,
                    directives=["DUMP", "LEGAL"])
    return setup, sp.run(lines)


def aura_board(lines=14000, spire=300000, deck_n=2000):
    """Aura- and trigger-heavy decks with a pre-built board: a crowded Field
    where every derived characteristic depends on several layered statics."""
    rng = random.Random(70101)
    blocks = card_blocks()
    aura = sorted(c for c, b in blocks.items() if "(aura" in b)
    trig = sorted(c for c, b in blocks.items() if "(on " in b)
    units = sorted(c for c, b in blocks.items() if "(type unit)" in b)
    sub = aura * 3 + trig * 2 + units
    fpool = set(G.field_pool())
    start = [c for c in aura + trig if c in fpool]
    setup = G.S(seed=70101, spire=spire, opening=6, shuffle="on",
                maxcap=14, handmax=9, turnlimit=100000,
                cap_a=4, cap_b=4,
                field_a=[rng.choice(start) for _ in range(14)],
                field_b=[rng.choice(start) for _ in range(14)],
                deck_a=deck(rng, sub, deck_n), deck_b=deck(rng, sub, deck_n))
    sp = BenchPlay(setup, 70102, focus=aura + trig, act_bias=0.9,
                    attack_bias=0.3, block_bias=0.6, directive_rate=0.0005,
                    error_rate=0.002, directives=["DUMP", "LEGAL"])
    return setup, sp.run(lines)


def mixed_session(lines=15000, spire=20000, deck_n=3000):
    """A long match driven like an interactive session: legal-action trace
    after every accepted action, inspection directives and rejected lines."""
    rng = random.Random(70201)
    pool = G.card_pool()
    sub_a = [c for c in pool if c[:3] in ("CIN", "LOM", "NEU")]
    sub_b = [c for c in pool if c[:3] in ("TID", "DSK", "NEU")]
    setup = G.S(seed=70201, spire=spire, opening=5, shuffle="on",
                turnlimit=100000, trace="legal",
                field_a=[rng.choice(G.field_pool()) for _ in range(3)],
                field_b=[rng.choice(G.field_pool()) for _ in range(3)],
                deck_a=deck(rng, sub_a, deck_n), deck_b=deck(rng, sub_b, deck_n))
    sp = BenchPlay(setup, 70202, act_bias=0.75, attack_bias=0.55,
                    block_bias=0.5, directive_rate=0.01, error_rate=0.01,
                    directives=["DUMP", "LEGAL", "CARD LOM-039",
                                "CARD NEU-006", "CARD DSK-013"])
    return setup, sp.run(lines)


# Long tier (bench-long/): the same three matches self-played for 3-8x as many
# script lines, with larger Spire and decks so the match does not end early.
# Self-play through the Python engine (which enumerates LEGAL before every
# action) is far slower than the implementations, so generation time (and,
# for 003's legal-action traces, output size) bounds the scale (see NOTES.md).
LONG_ARGS = {
    "001_long_match_throughput": (135000, 1000000, 16000),
    "002_aura_trigger_board": (110000, 1000000, 16000),
    "003_mixed_trace_session": (45000, 60000, 9000),
}

CASES = [
    ("001_long_match_throughput", long_match),
    ("002_aura_trigger_board", aura_board),
    ("003_mixed_trace_session", mixed_session),
]


def main():
    args = sys.argv[1:]
    long_tier = "--long" in args
    want = set(a for a in args if a != "--long")
    out_dir = os.path.join(os.path.dirname(BENCH), "bench-long") if long_tier else BENCH
    os.makedirs(out_dir, exist_ok=True)
    for name, build in CASES:
        if want and name not in want:
            continue
        setup, script = build(*LONG_ARGS[name]) if long_tier else build()
        text = G.mf(setup, script)
        out = G.ref.run_text(text)
        base = os.path.join(out_dir, name)
        with open(base + ".in", "w", encoding="utf-8", newline="") as f:
            f.write(text)
        with open(base + ".out", "w", encoding="utf-8", newline="") as f:
            f.write(out)
        print(name, "lines in", len(script), "bytes out", len(out),
              flush=True)


if __name__ == "__main__":
    main()
