#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the `orderbook` problem.

Hand-written edge cases are embedded as literal command lists; generated
workloads come from seeded random processes steered by a live copy of the
reference engine so that CANCEL/REPLACE mostly target orders that really
rest. Expected outputs are produced by reference/main.py and every test up to
BRUTE_LIMIT commands is cross-checked against an independent brute-force
engine (flat list of resting orders, best order found by a linear scan).
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
REF = os.path.join(HERE, "reference", "main.py")
sys.path.insert(0, os.path.join(HERE, "reference"))
from main import Book, BID, ASK  # noqa: E402

BRUTE_LIMIT = 25_000
MAX_COMMANDS = 200_000

cases = []


def add(name, cmds, trailing_newline=True):
    """trailing_newline=False writes the input without a newline after its
    last line, exercising the spec's allowance for a missing final newline."""
    assert len(cmds) <= MAX_COMMANDS
    cases.append((name, cmds, trailing_newline))


# ---------------------------------------------------------------------------
# Hand-written cases
# ---------------------------------------------------------------------------
add("empty", [])
add("book_empty", ["BOOK"])
add("single_rest", ["LIMIT b1 BUY 100 10", "BOOK", "LIMIT s1 SELL 105 3", "BOOK"])
add("full_fill_single_level", [
    "LIMIT b1 BUY 100 10",
    "LIMIT s1 SELL 100 10",
    "BOOK",
])
add("partial_fill_taker_rests", [
    "LIMIT s1 SELL 100 4",
    "LIMIT b1 BUY 100 10",
    "BOOK",
])
add("partial_fill_maker_remains", [
    "LIMIT b1 BUY 100 10",
    "LIMIT s1 SELL 95 4",
    "BOOK",
    "LIMIT s2 SELL 100 6",
    "BOOK",
])
add("sweep_levels_price_improvement", [
    "LIMIT s1 SELL 101 5",
    "LIMIT s2 SELL 103 5",
    "LIMIT s3 SELL 102 5",
    "LIMIT s4 SELL 104 5",
    "LIMIT b1 BUY 103 12",
    "BOOK",
    "LIMIT b2 BUY 110 1",
    "LIMIT b3 BUY 103 9",
    "BOOK",
])
add("time_priority_fifo", [
    "LIMIT b1 BUY 100 5",
    "LIMIT b2 BUY 100 5",
    "LIMIT b3 BUY 100 5",
    "LIMIT b4 BUY 101 2",
    "LIMIT s1 SELL 100 7",
    "BOOK",
    "LIMIT s2 SELL 100 6",
    "BOOK",
])
add("no_cross_rests", [
    "LIMIT b1 BUY 99 10",
    "LIMIT s1 SELL 100 10",
    "LIMIT b2 BUY 99 3",
    "LIMIT s2 SELL 101 4",
    "BOOK",
])
add("ioc_semantics", [
    "LIMIT s1 SELL 100 5",
    "LIMIT s2 SELL 101 5",
    "LIMIT b1 BUY 100 8 IOC",
    "BOOK",
    "LIMIT b2 BUY 99 8 IOC",
    "LIMIT b3 BUY 101 5 IOC",
    "BOOK",
    "CANCEL b1",
    "REPLACE b1 100 1",
    "LIMIT s3 SELL 50 1 IOC",
    "BOOK",
])
add("fok_reject_no_fills", [
    "LIMIT s1 SELL 100 5",
    "LIMIT s2 SELL 101 5",
    "LIMIT s3 SELL 200 100",
    "LIMIT b1 BUY 101 11 FOK",
    "BOOK",
    "LIMIT b2 BUY 99 1 FOK",
    "LIMIT b3 BUY 100 6 FOK",
    "BOOK",
    "CANCEL b1",
])
add("fok_fill_across_levels", [
    "LIMIT s1 SELL 100 5",
    "LIMIT s2 SELL 101 5",
    "LIMIT s3 SELL 102 5",
    "LIMIT b1 BUY 102 12 FOK",
    "BOOK",
    "LIMIT b2 BUY 102 3 FOK",
    "BOOK",
    "LIMIT b3 BUY 300 1 FOK",
])
add("fok_exact_quantity", [
    "LIMIT b1 BUY 100 3",
    "LIMIT b2 BUY 100 4",
    "LIMIT b3 BUY 99 3",
    "LIMIT s1 SELL 99 10 FOK",
    "BOOK",
    "LIMIT s2 SELL 99 10 FOK",
    "BOOK",
])
add("market_sweep", [
    "LIMIT b1 BUY 100 5",
    "LIMIT b2 BUY 99 5",
    "LIMIT b3 BUY 98 5",
    "LIMIT s1 SELL 200 2",
    "MARKET m1 SELL 12",
    "BOOK",
    "MARKET m2 SELL 10",
    "BOOK",
    "MARKET m3 BUY 2",
    "BOOK",
])
add("market_empty_book", [
    "MARKET m1 BUY 10",
    "MARKET m2 SELL 1",
    "BOOK",
    "LIMIT b1 BUY 5 1",
    "MARKET m3 BUY 3",
    "BOOK",
    "CANCEL m1",
    "REPLACE m3 5 1",
])
add("cancel_cases", [
    "CANCEL nope",
    "LIMIT b1 BUY 100 10",
    "LIMIT b2 BUY 100 10",
    "CANCEL b1",
    "CANCEL b1",
    "LIMIT s1 SELL 100 4",
    "CANCEL b2",
    "CANCEL b2",
    "LIMIT s2 SELL 100 4",
    "LIMIT b3 BUY 100 4",
    "CANCEL s2",
    "CANCEL b3",
    "LIMIT b4 BUY 100 4 IOC",
    "CANCEL b4",
    "LIMIT b5 BUY 100 4 FOK",
    "CANCEL b5",
    "BOOK",
])
add("replace_decrease_keeps_priority", [
    "LIMIT b1 BUY 100 10",
    "LIMIT b2 BUY 100 10",
    "REPLACE b1 100 4",
    "BOOK",
    "REPLACE b1 100 4",
    "LIMIT s1 SELL 100 6",
    "BOOK",
])
add("replace_increase_loses_priority", [
    "LIMIT b1 BUY 100 10",
    "LIMIT b2 BUY 100 10",
    "REPLACE b1 100 11",
    "BOOK",
    "LIMIT s1 SELL 100 12",
    "BOOK",
])
add("replace_price_change_rests", [
    "LIMIT b1 BUY 100 10",
    "LIMIT b2 BUY 101 10",
    "REPLACE b1 101 5",
    "BOOK",
    "REPLACE b2 99 10",
    "BOOK",
    "LIMIT s1 SELL 101 12",
    "BOOK",
])
add("replace_crosses_and_trades", [
    "LIMIT b1 BUY 100 10",
    "LIMIT s1 SELL 105 4",
    "LIMIT s2 SELL 106 4",
    "REPLACE b1 105 6",
    "BOOK",
    "REPLACE b1 110 20",
    "BOOK",
    "REPLACE b1 110 3",
    "CANCEL b1",
    "BOOK",
])
add("replace_rejects", [
    "REPLACE ghost 100 1",
    "LIMIT b1 BUY 100 5",
    "LIMIT s1 SELL 100 5",
    "REPLACE b1 100 1",
    "REPLACE s1 100 1",
    "LIMIT b2 BUY 100 5",
    "CANCEL b2",
    "REPLACE b2 100 1",
    "LIMIT b3 BUY 100 5 IOC",
    "REPLACE b3 100 1",
    "LIMIT b4 BUY 100 5",
    "LIMIT s2 SELL 100 2",
    "REPLACE b4 100 3",
    "REPLACE b4 100 4",
    "BOOK",
])
add("book_ordering_many_levels", [
    "LIMIT b1 BUY 95 1",
    "LIMIT b2 BUY 100 2",
    "LIMIT b3 BUY 97 3",
    "LIMIT b4 BUY 100 4",
    "LIMIT b5 BUY 1 5",
    "LIMIT s1 SELL 103 1",
    "LIMIT s2 SELL 101 2",
    "LIMIT s3 SELL 1000000000 3",
    "LIMIT s4 SELL 101 4",
    "LIMIT s5 SELL 102 5",
    "BOOK",
    "CANCEL b2",
    "CANCEL s2",
    "BOOK",
])
add("large_quantities", [
    "LIMIT b1 BUY 1000000000 1000000000",
    "LIMIT b2 BUY 1000000000 1000000000",
    "LIMIT b3 BUY 1000000000 1000000000",
    "LIMIT b4 BUY 1000000000 1000000000",
    "LIMIT b5 BUY 1000000000 1000000000",
    "BOOK",
    "LIMIT s1 SELL 1 1000000000 FOK",
    "MARKET m1 SELL 1000000000",
    "LIMIT s2 SELL 999999999 1000000000 IOC",
    "BOOK",
    "REPLACE b5 1000000000 999999999",
    "LIMIT s3 SELL 1 1000000000 FOK",
    "BOOK",
])
add("id_characters", [
    "LIMIT !\"#$%&'()*+,-./ BUY 10 1",
    "LIMIT :;<=>?@[\\]^_`{|}~ SELL 20 1",
    "LIMIT 0123456789abcdefghijklmnopqrstuv BUY 10 1",
    "LIMIT BUY SELL 30 2",
    "LIMIT SELL BUY 9 2",
    "LIMIT BOOK SELL 9 3",
    "BOOK",
    "CANCEL !\"#$%&'()*+,-./",
    "CANCEL sell",
    "REPLACE BUY 30 1",
    "BOOK",
])
add("same_price_both_sides", [
    "LIMIT b1 BUY 100 5",
    "LIMIT s1 SELL 100 5",
    "LIMIT s2 SELL 100 5",
    "LIMIT b2 BUY 100 5",
    "LIMIT b3 BUY 100 2 FOK",
    "LIMIT s3 SELL 100 3 IOC",
    "BOOK",
])
add("both_sides_fill_same_trade", [
    "LIMIT s1 SELL 100 5",
    "LIMIT s2 SELL 100 5",
    "LIMIT b1 BUY 100 10",
    "LIMIT b2 BUY 100 10",
    "MARKET m1 SELL 10",
    "MARKET m2 SELL 1",
    "BOOK",
])
add("no_trailing_newline", [
    "LIMIT b1 BUY 100 5",
    "LIMIT b2 BUY 99 5",
    "BOOK",
    "LIMIT s1 SELL 99 12 IOC",
], trailing_newline=False)

# ---------------------------------------------------------------------------
# Independent brute-force engine used to cross-check expected outputs
# ---------------------------------------------------------------------------
class Brute:
    """Flat-list order book: every operation scans all resting orders."""

    def __init__(self):
        self.book = []      # dicts: id, side, price, rem, seq
        self.seq = 0
        self.out = []
        self.resting = {}   # id -> dict while resting

    def crossing(self, side, limit):
        res = []
        for o in self.book:
            if o["side"] == side:
                continue
            if limit is None or (side == "BUY" and o["price"] <= limit) or (side == "SELL" and o["price"] >= limit):
                res.append(o)
        return res

    def best(self, side, limit):
        cands = self.crossing(side, limit)
        if not cands:
            return None
        if side == "BUY":
            return min(cands, key=lambda o: (o["price"], o["seq"]))
        return min(cands, key=lambda o: (-o["price"], o["seq"]))

    def fill(self, oid, side, limit, qty):
        while qty > 0:
            m = self.best(side, limit)
            if m is None:
                break
            t = min(qty, m["rem"])
            self.out.append("TRADE %s %s %d %d" % (oid, m["id"], m["price"], t))
            m["rem"] -= t
            qty -= t
            if m["rem"] == 0:
                self.book.remove(m)
                del self.resting[m["id"]]
                self.out.append("FILLED %s" % m["id"])
        return qty

    def rest(self, oid, side, price, qty):
        self.seq += 1
        o = {"id": oid, "side": side, "price": price, "rem": qty, "seq": self.seq}
        self.book.append(o)
        self.resting[oid] = o

    def limit(self, oid, side, price, qty, flag):
        if flag == "FOK":
            if sum(o["rem"] for o in self.crossing(side, price)) < qty:
                self.out.append("REJECT %s" % oid)
                return
        rem = self.fill(oid, side, price, qty)
        if rem == 0:
            self.out.append("FILLED %s" % oid)
        elif flag == "IOC":
            self.out.append("CANCEL %s %d" % (oid, rem))
        else:
            self.rest(oid, side, price, rem)
            self.out.append("REST %s" % oid)

    def run(self, cmds):
        for line in cmds:
            p = line.split()
            if p[0] == "LIMIT":
                self.limit(p[1], p[2], int(p[3]), int(p[4]), p[5] if len(p) > 5 else None)
            elif p[0] == "MARKET":
                rem = self.fill(p[1], p[2], None, int(p[3]))
                self.out.append(("FILLED %s" % p[1]) if rem == 0 else ("CANCEL %s %d" % (p[1], rem)))
            elif p[0] == "CANCEL":
                o = self.resting.get(p[1])
                if o is None:
                    self.out.append("REJECT %s" % p[1])
                else:
                    self.book.remove(o)
                    del self.resting[p[1]]
                    self.out.append("CANCEL %s %d" % (p[1], o["rem"]))
            elif p[0] == "REPLACE":
                o = self.resting.get(p[1])
                price, qty = int(p[2]), int(p[3])
                if o is None:
                    self.out.append("REJECT %s" % p[1])
                elif price == o["price"] and qty <= o["rem"]:
                    o["rem"] = qty
                    self.out.append("REST %s" % p[1])
                else:
                    self.book.remove(o)
                    del self.resting[p[1]]
                    self.limit(p[1], o["side"], price, qty, None)
            elif p[0] == "BOOK":
                levels = {}
                for o in self.book:
                    key = (o["side"], o["price"])
                    tq, n = levels.get(key, (0, 0))
                    levels[key] = (tq + o["rem"], n + 1)
                for price in sorted({k[1] for k in levels if k[0] == "BUY"}, reverse=True):
                    tq, n = levels[("BUY", price)]
                    self.out.append("BID %d %d %d" % (price, tq, n))
                for price in sorted({k[1] for k in levels if k[0] == "SELL"}):
                    tq, n = levels[("SELL", price)]
                    self.out.append("ASK %d %d %d" % (price, tq, n))
                self.out.append("--")
            else:
                raise ValueError(line)
        return self.out


# ---------------------------------------------------------------------------
# Generated workloads
# ---------------------------------------------------------------------------
ID_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz"


def short_id(n):
    s = ""
    while True:
        s = ID_ALPHABET[n % 36] + s
        n //= 36
        if n == 0:
            return s


class Workload:
    """Builds a command list while running the reference engine on it, so
    that cancels and replaces can target orders that are really resting."""

    def __init__(self, seed, mid=10_000, spread=20, walk=3, qmax=100):
        self.rng = random.Random(seed)
        self.cmds = []
        self.book = Book([])
        self.mid = mid
        self.spread = spread
        self.walk = walk
        self.qmax = qmax
        self.next_id = 0
        self.rested = []

    def new_id(self):
        self.next_id += 1
        return short_id(self.next_id)

    def emit(self, line):
        self.cmds.append(line)
        parts = line.split()
        b = self.book
        cmd = parts[0]
        if cmd == "LIMIT":
            side = BID if parts[2] == "BUY" else ASK
            b.limit(parts[1], side, int(parts[3]), int(parts[4]), parts[5] if len(parts) > 5 else None)
            if b.orders[parts[1]].resting:
                self.rested.append(parts[1])
        elif cmd == "MARKET":
            b.market(parts[1], BID if parts[2] == "BUY" else ASK, int(parts[3]))
        elif cmd == "CANCEL":
            b.cancel(parts[1])
        elif cmd == "REPLACE":
            b.replace(parts[1], int(parts[2]), int(parts[3]))
            o = b.orders.get(parts[1])
            if o is not None and o.resting:
                self.rested.append(parts[1])
        elif cmd == "BOOK":
            b.print_book()
        b.out.clear()

    def resting_id(self):
        """A random currently-resting id, or a stale/unknown one occasionally."""
        rng = self.rng
        if rng.random() < 0.05 or not self.rested:
            return rng.choice(["ghost", short_id(rng.randint(1, max(1, self.next_id))), "x"])
        if len(self.rested) > 200 and rng.random() < 0.02:
            live = sum(level[2] for side in self.book.sides for level in side.levels.values())
            if len(self.rested) > 4 * live + 100:
                self.rested = [oid for oid in self.rested if self.book.orders[oid].resting]
                if not self.rested:
                    return "ghost"
        for _ in range(16):
            oid = rng.choice(self.rested)
            if self.book.orders[oid].resting:
                return oid
        return rng.choice(self.rested)

    def price_near(self, side, aggressive):
        rng = self.rng
        off = rng.randint(0, self.spread)
        if aggressive:
            return self.mid + off if side == "BUY" else max(1, self.mid - off)
        return max(1, self.mid - off) if side == "BUY" else self.mid + off

    def step(self, p_limit=0.55, p_market=0.08, p_cancel=0.17, p_replace=0.15, p_book=0.05, p_aggr=0.35, p_flag=0.15):
        rng = self.rng
        if rng.random() < 0.02:
            self.mid = max(self.spread + 1, self.mid + rng.randint(-self.walk, self.walk))
        kind = rng.choices(("LIMIT", "MARKET", "CANCEL", "REPLACE", "BOOK"),
                           (p_limit, p_market, p_cancel, p_replace, p_book))[0]
        if kind == "LIMIT":
            side = rng.choice(("BUY", "SELL"))
            price = self.price_near(side, rng.random() < p_aggr)
            qty = rng.randint(1, self.qmax)
            flag = ""
            if rng.random() < p_flag:
                flag = rng.choice((" IOC", " FOK"))
            self.emit("LIMIT %s %s %d %d%s" % (self.new_id(), side, price, qty, flag))
        elif kind == "MARKET":
            self.emit("MARKET %s %s %d" % (self.new_id(), rng.choice(("BUY", "SELL")), rng.randint(1, self.qmax * 3)))
        elif kind == "CANCEL":
            self.emit("CANCEL %s" % self.resting_id())
        elif kind == "REPLACE":
            oid = self.resting_id()
            o = self.book.orders.get(oid)
            if o is not None and o.resting and rng.random() < 0.7:
                k = rng.random()
                if k < 0.4:
                    price, qty = o.price, rng.randint(1, o.rem)
                elif k < 0.6:
                    price, qty = o.price, o.rem + rng.randint(1, self.qmax)
                else:
                    side = "BUY" if o.side == BID else "SELL"
                    price, qty = self.price_near(side, rng.random() < 0.3), rng.randint(1, self.qmax)
            else:
                price, qty = self.price_near(rng.choice(("BUY", "SELL")), False), rng.randint(1, self.qmax)
            self.emit("REPLACE %s %d %d" % (oid, price, qty))
        else:
            self.emit("BOOK")

    def run(self, n, **kw):
        for _ in range(n):
            self.step(**kw)
        return self.cmds


def gen_random(seed, n, **kw):
    w = Workload(seed, **{k: v for k, v in kw.items() if k in ("mid", "spread", "walk", "qmax")})
    step_kw = {k: v for k, v in kw.items() if k not in ("mid", "spread", "walk", "qmax")}
    return w.run(n, **step_kw)


add("gen_small_random", gen_random(1, 300, spread=5, qmax=20))
add("gen_small_flags", gen_random(2, 500, spread=8, qmax=30, p_flag=0.6, p_aggr=0.5))
add("gen_medium_random", gen_random(3, 5_000, spread=30, qmax=50))
add("gen_medium_wide_prices", gen_random(4, 10_000, spread=2_000, walk=200, qmax=50, p_aggr=0.25, p_book=0.01))
add("gen_medium_fok_ioc_heavy", gen_random(5, 20_000, spread=25, qmax=80, p_flag=0.7, p_aggr=0.5, p_cancel=0.1, p_replace=0.05, p_limit=0.7))
add("gen_medium_replace_cancel_heavy", gen_random(6, 20_000, spread=15, qmax=40, p_limit=0.4, p_market=0.05, p_cancel=0.25, p_replace=0.28, p_aggr=0.3))


def gen_deep_book_sweep(seed, n_rest, n_sweep):
    """Builds a deep book of resting orders, then sweeps it with big market
    and limit orders so every command touches many levels and makers."""
    w = Workload(seed, mid=50_000, spread=5_000, qmax=10)
    rng = w.rng
    for _ in range(n_rest):
        side = rng.choice(("BUY", "SELL"))
        w.emit("LIMIT %s %s %d %d" % (w.new_id(), side, w.price_near(side, False), rng.randint(1, 10)))
    w.emit("BOOK")
    for i in range(n_sweep):
        side = rng.choice(("BUY", "SELL"))
        r = rng.random()
        if r < 0.5:
            w.emit("MARKET %s %s %d" % (w.new_id(), side, rng.randint(1, 400)))
        elif r < 0.8:
            price = w.mid + rng.randint(-6_000, 6_000)
            w.emit("LIMIT %s %s %d %d %s" % (w.new_id(), side, max(1, price), rng.randint(50, 600), rng.choice(("IOC", "FOK", "FOK"))))
        else:
            price = w.mid + rng.randint(-6_000, 6_000)
            w.emit("LIMIT %s %s %d %d" % (w.new_id(), side, max(1, price), rng.randint(1, 300)))
        if i % 2500 == 2499:
            w.emit("BOOK")
    return w.cmds


add("gen_perf_narrow_200k", gen_random(7, 200_000, spread=10, walk=2, qmax=60, p_book=0.01, p_aggr=0.3, p_flag=0.2))
add("gen_perf_wide_levels_80k", gen_random(8, 80_000, mid=500_000, spread=100_000, walk=2_000, qmax=30, p_aggr=0.1, p_limit=0.78, p_market=0.04, p_cancel=0.08, p_replace=0.1, p_book=0.00004))
add("gen_perf_deep_sweep_60k", gen_deep_book_sweep(9, 45_000, 14_999))
add("gen_perf_churn_200k", gen_random(10, 200_000, spread=40, walk=6, qmax=1_000_000_000, p_limit=0.45, p_market=0.1, p_cancel=0.22, p_replace=0.2, p_book=0.01, p_aggr=0.35, p_flag=0.3))


# ---------------------------------------------------------------------------
# Emit files
# ---------------------------------------------------------------------------
def main():
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        os.remove(os.path.join(TESTS, f))
    total = 0
    for i, (name, cmds, trailing_newline) in enumerate(cases, 1):
        base = "%03d_%s" % (i, name)
        text = "%d\n" % len(cmds) + "".join(c + "\n" for c in cmds)
        if not trailing_newline:
            text = text[:-1]
        with open(os.path.join(TESTS, base + ".in"), "w") as f:
            f.write(text)
        proc = subprocess.run([sys.executable, REF], input=text.encode(), capture_output=True)
        if proc.returncode != 0:
            print("reference failed on", base, proc.stderr.decode())
            sys.exit(1)
        out = proc.stdout.decode()
        with open(os.path.join(TESTS, base + ".out"), "w") as f:
            f.write(out)
        # The output of the first k commands is a prefix of the whole output,
        # so a large test is cross-checked on its first BRUTE_LIMIT commands.
        prefix = cmds[:BRUTE_LIMIT]
        expect = "".join(line + "\n" for line in Brute().run(prefix))
        if not out.startswith(expect):
            print("brute-force disagreement on", base)
            a, b = expect.split("\n"), out.split("\n")
            for k, (x, y) in enumerate(zip(a, b)):
                if x != y:
                    print("line", k + 1, "brute:", x, "ref:", y)
                    break
            sys.exit(1)
        checked = "checked" if len(prefix) == len(cmds) else "prefix-checked"
        total += len(text) + len(out)
        print("%-40s %7d cmds %9d in %9d out  %s" % (base, len(cmds), len(text), len(out), checked))
    print("total bytes: %d" % total)


if __name__ == "__main__":
    main()
