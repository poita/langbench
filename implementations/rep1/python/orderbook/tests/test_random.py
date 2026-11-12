"""Randomized differential tests against a naive reference implementation."""

import random

import pytest

from orderbook import OrderBook, parse_command
from reference import NaiveBook


def gen(rng, n, price_range, qty_max):
    ids, cmds = [], []
    nxt = 0
    for _ in range(n):
        r = rng.random()
        if r < 0.45 or (r < 0.6 and not ids):
            nxt += 1
            i = f"o{nxt}"
            ids.append(i)
            tif = rng.choice(["", "", "", " IOC", " FOK"])
            cmds.append(f"LIMIT {i} {rng.choice(['BUY', 'SELL'])} "
                        f"{rng.randint(*price_range)} {rng.randint(1, qty_max)}{tif}")
        elif r < 0.52:
            nxt += 1
            i = f"o{nxt}"
            ids.append(i)
            cmds.append(f"MARKET {i} {rng.choice(['BUY', 'SELL'])} {rng.randint(1, qty_max)}")
        elif r < 0.68:
            cmds.append(f"CANCEL {rng.choice(ids + ['zz'])}")
        elif r < 0.88:
            cmds.append(f"REPLACE {rng.choice(ids + ['zz'])} "
                        f"{rng.randint(*price_range)} {rng.randint(1, qty_max)}")
        else:
            cmds.append("BOOK")
    return cmds


@pytest.mark.parametrize("seed", range(40))
def test_matches_reference(seed):
    rng = random.Random(seed)
    cmds = gen(rng, 400, (95, 105) if seed % 2 else (1, 1000), rng.choice([3, 20, 10**9]))
    book, ref = OrderBook(), NaiveBook()
    for c in cmds:
        got = [str(e) for e in book.execute(parse_command(c))]
        assert got == ref.run(c), c
