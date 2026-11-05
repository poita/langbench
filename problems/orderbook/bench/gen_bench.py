#!/usr/bin/env python3
"""Generates the orderbook performance benchmark inputs and expected outputs.

Writes bench/NNN_name.in and bench/NNN_name.out in the same layout as tests/,
so `run_tests.py orderbook --tests-dir problems/orderbook/bench` works.

Every workload is built by a seeded random process that drives a live copy of
the reference engine, so cancels and replaces target orders that really rest
and the book size can be steered. Each input uses the spec's maximum of
200 000 commands and stays within its other limits (at most ~45 000 resting
orders, at most ~12 000 price levels per side, output under 10 MB). Expected
outputs are produced by reference/main.py.
"""
import os
import random
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
REF = os.path.join(PROBLEM, "reference", "main.py")
sys.path.insert(0, os.path.join(PROBLEM, "reference"))
from main import Book, BID, ASK  # noqa: E402

N_COMMANDS = 200_000
MAX_RESTING = 45_000
MAX_LEVELS = 12_000
MAX_OUTPUT = 10_000_000

# Long tier (bench-long/): the same three workloads run for 8x as many
# commands with the same book-size limits. SPEC.md allows up to 2 000 000
# commands and 100 MB of output.
LONG_COMMANDS = 1_600_000
LONG_MAX_OUTPUT = 100_000_000

ID_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz"


def short_id(n):
    s = ""
    while True:
        s = ID_ALPHABET[n % 36] + s
        n //= 36
        if n == 0:
            return s


class Gen:
    """Command builder that mirrors every command into the reference engine
    and tracks the exact set of resting ids from the emitted events."""

    def __init__(self, seed, id_prefix=""):
        self.rng = random.Random(seed)
        self.cmds = []
        self.book = Book([])
        self.next_id = 0
        self.id_prefix = id_prefix
        self.live = []          # resting ids, for O(1) random choice
        self.live_pos = {}      # id -> index in live
        self.out_bytes = 0
        self.max_resting = 0
        self.max_levels = 0

    def new_id(self):
        self.next_id += 1
        return self.id_prefix + short_id(self.next_id)

    def _add(self, oid):
        if oid not in self.live_pos:
            self.live_pos[oid] = len(self.live)
            self.live.append(oid)

    def _remove(self, oid):
        i = self.live_pos.pop(oid, None)
        if i is None:
            return
        last = self.live.pop()
        if i < len(self.live):
            self.live[i] = last
            self.live_pos[last] = i

    def emit(self, line):
        self.cmds.append(line)
        p = line.split()
        b = self.book
        cmd = p[0]
        if cmd == "LIMIT":
            b.limit(p[1], BID if p[2] == "BUY" else ASK, int(p[3]), int(p[4]), p[5] if len(p) > 5 else None)
        elif cmd == "MARKET":
            b.market(p[1], BID if p[2] == "BUY" else ASK, int(p[3]))
        elif cmd == "CANCEL":
            b.cancel(p[1])
        elif cmd == "REPLACE":
            b.replace(p[1], int(p[2]), int(p[3]))
        else:
            b.print_book()
        for ev in b.out:
            self.out_bytes += len(ev) + 1
            if ev[0] == "R" and ev[1] == "E" and ev[2] == "S":      # REST
                self._add(ev[5:])
            elif ev[0] == "F":                                     # FILLED
                self._remove(ev[7:])
            elif ev[0] == "C":                                     # CANCEL id qty
                self._remove(ev[7:ev.rindex(" ")])
        b.out.clear()
        self.max_resting = max(self.max_resting, len(self.live))
        if cmd != "CANCEL":
            self.max_levels = max(self.max_levels, len(b.sides[0].keys), len(b.sides[1].keys))

    def resting(self):
        return len(self.live)

    def random_live(self):
        return self.live[self.rng.randrange(len(self.live))] if self.live else "ghost"

    def best(self, side):
        """Best price on a side (BID/ASK) or None."""
        s = self.book.sides[side]
        return s.keys[-1] * s.sign if s.keys else None

    def n_levels(self, side):
        return len(self.book.sides[side].keys)


# ---------------------------------------------------------------------------
# 001: steady continuous trading
# ---------------------------------------------------------------------------
def gen_steady_flow(seed):
    """A liquid market around a slowly drifting mid: passive quotes, marketable
    limit orders, market orders, IOC/FOK, cancels and replaces in proportions
    typical of an exchange feed, with a few hundred active price levels and
    ~20k resting orders. Periodic BOOK snapshots."""
    g = Gen(seed)
    rng = g.rng
    mid, spread = 250_000, 150
    target = 20_000
    for _ in range(target):
        side = rng.choice(("BUY", "SELL"))
        off = int(rng.expovariate(1 / 40)) + 1
        price = mid - off if side == "BUY" else mid + off
        g.emit("LIMIT %s %s %d %d" % (g.new_id(), side, price, rng.randint(1, 500)))
    while len(g.cmds) < N_COMMANDS:
        if rng.random() < 0.03:
            mid += rng.randint(-3, 3)
        r = rng.random()
        # Steer the resting count toward the target via the cancel share.
        p_cancel = 0.22 if g.resting() > target else 0.12
        if r < 0.40:
            side = rng.choice(("BUY", "SELL"))
            off = int(rng.expovariate(1 / 40)) + 1
            if rng.random() < 0.25:   # marketable: reaches across the spread
                off = -rng.randint(1, 30)
            price = max(1, mid - off if side == "BUY" else mid + off)
            flag = rng.choices(("", " IOC", " FOK"), (0.84, 0.1, 0.06))[0]
            g.emit("LIMIT %s %s %d %d%s" % (g.new_id(), side, price, rng.randint(1, 500), flag))
        elif r < 0.44:
            g.emit("MARKET %s %s %d" % (g.new_id(), rng.choice(("BUY", "SELL")), rng.randint(1, 2_000)))
        elif r < 0.44 + p_cancel:
            g.emit("CANCEL %s" % (g.random_live() if rng.random() < 0.95 else short_id(rng.randint(1, g.next_id))))
        elif r < 0.44 + p_cancel + 0.2:
            oid = g.random_live()
            o = g.book.orders.get(oid)
            if o is None or not o.resting:
                g.emit("REPLACE %s %d %d" % (oid, mid, 1))
                continue
            k = rng.random()
            if k < 0.45:
                price, qty = o.price, rng.randint(1, o.rem)
            elif k < 0.6:
                price, qty = o.price, o.rem + rng.randint(1, 200)
            else:
                off = int(rng.expovariate(1 / 30)) + 1
                price = max(1, mid - off if o.side == BID else mid + off)
                qty = rng.randint(1, 500)
            g.emit("REPLACE %s %d %d" % (oid, price, qty))
        elif r < 0.44 + p_cancel + 0.2 + 0.001:
            g.emit("BOOK")
    return g


# ---------------------------------------------------------------------------
# 002: deep price ladder with fill-or-kill block orders
# ---------------------------------------------------------------------------
def gen_deep_ladder_fok(seed):
    """A book spread over ~11-12k distinct price levels per side (~44k resting
    orders). Large fill-or-kill block orders probe liquidity hundreds or
    thousands of levels deep (most are rejected, so the cost is in summing the
    crossed levels, not in printing trades), interleaved with level-creating
    passive orders, cancels that empty levels, price-moving replaces and
    ordinary marketable flow at the top of the book."""
    g = Gen(seed)
    rng = g.rng
    mid, width = 2_000_000, MAX_LEVELS - 100
    target = 44_000

    def passive_price(side):
        if rng.random() < 0.3:
            off = min(width, int(rng.expovariate(1 / 800)) + 1)
        else:
            off = rng.randint(1, width)
        return mid - off if side == "BUY" else mid + off

    for _ in range(target):
        side = rng.choice(("BUY", "SELL"))
        g.emit("LIMIT %s %s %d %d" % (g.new_id(), side, passive_price(side), rng.randint(1, 200)))
    while len(g.cmds) < N_COMMANDS:
        r = rng.random()
        if r < 0.24:
            # Fill-or-kill block: limit d ticks through the opposite best.
            side = rng.choice(("BUY", "SELL"))
            opp = ASK if side == "BUY" else BID
            best = g.best(opp)
            if best is None:
                continue
            d = int(3_000 ** rng.random())        # log-uniform 1..3000 ticks
            limit = best + d if side == "BUY" else max(1, best - d)
            avail = 0
            s = g.book.sides[opp]
            for key in reversed(s.keys):
                price = key * s.sign
                if (side == "BUY" and price > limit) or (side == "SELL" and price < limit):
                    break
                avail += s.levels[price][1]
            if d <= 12 and rng.random() < 0.6:
                qty = max(1, int(avail * rng.uniform(0.3, 1.0)))   # fills
            else:
                qty = int(avail * rng.uniform(1.02, 2.0)) + 1      # rejected
            qty = min(qty, 1_000_000_000)
            g.emit("LIMIT %s %s %d %d FOK" % (g.new_id(), side, limit, qty))
        elif r < 0.56:
            side = rng.choice(("BUY", "SELL"))
            g.emit("LIMIT %s %s %d %d" % (g.new_id(), side, passive_price(side), rng.randint(1, 200)))
        elif r < 0.64:
            # Marketable flow at the top of the book.
            side = rng.choice(("BUY", "SELL"))
            opp = ASK if side == "BUY" else BID
            best = g.best(opp)
            if best is None:
                continue
            d = rng.randint(0, 5)
            price = best + d if side == "BUY" else max(1, best - d)
            flag = rng.choice(("", " IOC"))
            g.emit("LIMIT %s %s %d %d%s" % (g.new_id(), side, price, rng.randint(1, 400), flag))
        elif r < 0.66:
            g.emit("MARKET %s %s %d" % (g.new_id(), rng.choice(("BUY", "SELL")), rng.randint(1, 600)))
        elif r < 0.66 + (0.22 if g.resting() > target else 0.14):
            g.emit("CANCEL %s" % g.random_live())
        else:
            oid = g.random_live()
            o = g.book.orders.get(oid)
            if o is None or not o.resting:
                continue
            if rng.random() < 0.4:
                price, qty = o.price, rng.randint(1, o.rem)
            else:
                price, qty = passive_price("BUY" if o.side == BID else "SELL"), rng.randint(1, 200)
            g.emit("REPLACE %s %d %d" % (oid, price, qty))
        if len(g.cmds) % 50_000 == 0:
            g.emit("BOOK")
    return g


# ---------------------------------------------------------------------------
# 003: deep FIFO queues with heavy cancel/replace churn
# ---------------------------------------------------------------------------
def gen_queue_churn(seed):
    """A tight market (a handful of ticks per side) where ~40k orders queue at
    few prices, so every level holds thousands of orders. Most traffic is
    cancels and replaces aimed at random queue positions (as from market
    makers re-quoting), plus aggressive orders that eat through the queue
    fronts, many small makers per taker."""
    g = Gen(seed, id_prefix="mm-")
    rng = g.rng
    mid, spread = 75_000, 12
    target = 40_000
    for _ in range(target):
        side = rng.choice(("BUY", "SELL"))
        off = rng.randint(1, spread)
        g.emit("LIMIT %s %s %d %d" % (g.new_id(), side, mid - off if side == "BUY" else mid + off, rng.randint(1, 50)))
    while len(g.cmds) < N_COMMANDS:
        if rng.random() < 0.01:
            mid += rng.randint(-1, 1)
        r = rng.random()
        if r < 0.30:
            side = rng.choice(("BUY", "SELL"))
            off = rng.randint(1, spread)
            price = mid - off if side == "BUY" else mid + off
            g.emit("LIMIT %s %s %d %d" % (g.new_id(), side, price, rng.randint(1, 50)))
        elif r < 0.37:
            side = rng.choice(("BUY", "SELL"))
            off = rng.randint(0, 3)
            price = mid + off if side == "BUY" else mid - off
            flag = rng.choices(("", " IOC", " FOK"), (0.5, 0.35, 0.15))[0]
            g.emit("LIMIT %s %s %d %d%s" % (g.new_id(), side, price, rng.randint(20, 600), flag))
        elif r < 0.40:
            g.emit("MARKET %s %s %d" % (g.new_id(), rng.choice(("BUY", "SELL")), rng.randint(20, 800)))
        elif r < 0.40 + (0.36 if g.resting() > target else 0.28):
            g.emit("CANCEL %s" % (g.random_live() if rng.random() < 0.97 else "mm-" + short_id(rng.randint(1, g.next_id))))
        else:
            oid = g.random_live()
            o = g.book.orders.get(oid)
            if o is None or not o.resting:
                continue
            k = rng.random()
            if k < 0.5:
                price, qty = o.price, rng.randint(1, o.rem)          # keeps priority
            elif k < 0.7:
                price, qty = o.price, o.rem + rng.randint(1, 30)     # back of queue
            else:
                off = rng.randint(1, spread)
                price = mid - off if o.side == BID else mid + off
                qty = rng.randint(1, 50)
            g.emit("REPLACE %s %d %d" % (oid, price, qty))
        if rng.random() < 0.0005:
            g.emit("BOOK")
    return g


CASES = [
    ("steady_flow_200k", gen_steady_flow, 101),
    ("deep_ladder_fok_200k", gen_deep_ladder_fok, 102),
    ("queue_churn_200k", gen_queue_churn, 103),
]


def main():
    global N_COMMANDS, MAX_OUTPUT
    args = sys.argv[1:]
    out_dir = HERE
    if "--long" in args:
        args.remove("--long")
        N_COMMANDS, MAX_OUTPUT = LONG_COMMANDS, LONG_MAX_OUTPUT
        out_dir = os.path.join(PROBLEM, "bench-long")
        os.makedirs(out_dir, exist_ok=True)
    only = set(args)
    for i, (name, fn, seed) in enumerate(CASES, 1):
        base = "%03d_%s" % (i, name)
        if only and base not in only and name not in only:
            continue
        g = fn(seed)
        cmds = g.cmds[:N_COMMANDS]
        text = "%d\n" % len(cmds) + "".join(c + "\n" for c in cmds)
        with open(os.path.join(out_dir, base + ".in"), "w") as f:
            f.write(text)
        proc = subprocess.run([sys.executable, REF], input=text.encode(), capture_output=True)
        if proc.returncode != 0:
            sys.exit("reference failed on %s: %s" % (base, proc.stderr.decode()))
        out = proc.stdout
        assert len(out) < MAX_OUTPUT, (base, len(out))
        with open(os.path.join(out_dir, base + ".out"), "wb") as f:
            f.write(out)
        print("%-28s %7d cmds %9d in %9d out  max resting %d, max levels/side %d"
              % (base, len(cmds), len(text), len(out), g.max_resting, g.max_levels))


if __name__ == "__main__":
    main()
