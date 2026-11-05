#!/usr/bin/env python3
"""Reference limit order book matching engine (price-time priority).

Each side keeps a dict price -> level and a sorted list of price keys with the
best price at the end (bids: key = price, asks: key = -price). A level is
[deque of orders, total resting qty, number of resting orders]. Orders that
are cancelled or replaced are dropped lazily: the order object is flagged as
not resting and skipped when it reaches the front of its deque, while the
level totals are adjusted immediately so BOOK and FOK checks stay exact.
"""
import sys
from bisect import bisect_left, insort
from collections import deque

BID, ASK = 0, 1


class Order:
    __slots__ = ("oid", "side", "price", "rem", "resting")

    def __init__(self, oid, side, price, rem):
        self.oid = oid
        self.side = side
        self.price = price
        self.rem = rem
        self.resting = False


class Side:
    __slots__ = ("levels", "keys", "sign")

    def __init__(self, sign):
        self.levels = {}
        self.keys = []
        self.sign = sign  # +1 for bids, -1 for asks: key = sign * price


class Book:
    def __init__(self, out):
        self.sides = (Side(1), Side(-1))
        self.orders = {}
        self.out = out

    def crosses(self, taker_side, price, limit):
        if limit is None:
            return True
        return price <= limit if taker_side == BID else price >= limit

    def available(self, taker_side, limit, need):
        """Sums crossing resting quantity best-first until it reaches need."""
        opp = self.sides[1 - taker_side]
        total = 0
        for key in reversed(opp.keys):
            price = key * opp.sign
            if not self.crosses(taker_side, price, limit):
                break
            total += opp.levels[price][1]
            if total >= need:
                return True
        return False

    def match(self, order, limit):
        """Fills order against the opposite side; returns remaining qty."""
        out = self.out
        opp = self.sides[1 - order.side]
        keys = opp.keys
        levels = opp.levels
        q = order.rem
        oid = order.oid
        while q > 0 and keys:
            price = keys[-1] * opp.sign
            if not self.crosses(order.side, price, limit):
                break
            level = levels[price]
            dq = level[0]
            while q > 0 and dq:
                maker = dq[0]
                if not maker.resting:
                    dq.popleft()
                    continue
                t = q if q < maker.rem else maker.rem
                out.append("TRADE %s %s %d %d" % (oid, maker.oid, price, t))
                maker.rem -= t
                q -= t
                level[1] -= t
                if maker.rem == 0:
                    maker.resting = False
                    dq.popleft()
                    level[2] -= 1
                    out.append("FILLED %s" % maker.oid)
            if level[2] == 0:
                del levels[price]
                keys.pop()
        order.rem = q
        return q

    def rest(self, order):
        side = self.sides[order.side]
        level = side.levels.get(order.price)
        if level is None:
            level = [deque(), 0, 0]
            side.levels[order.price] = level
            insort(side.keys, order.price * side.sign)
        level[0].append(order)
        level[1] += order.rem
        level[2] += 1
        order.resting = True

    def unrest(self, order):
        """Removes a resting order's quantity from its level bookkeeping."""
        side = self.sides[order.side]
        level = side.levels[order.price]
        level[1] -= order.rem
        level[2] -= 1
        order.resting = False
        if level[2] == 0:
            del side.levels[order.price]
            del side.keys[bisect_left(side.keys, order.price * side.sign)]

    def limit(self, oid, side, price, qty, flag):
        out = self.out
        order = Order(oid, side, price, qty)
        self.orders[oid] = order
        if flag == "FOK" and not self.available(side, price, qty):
            out.append("REJECT %s" % oid)
            return
        rem = self.match(order, price)
        if rem == 0:
            out.append("FILLED %s" % oid)
        elif flag == "IOC":
            out.append("CANCEL %s %d" % (oid, rem))
        else:
            self.rest(order)
            out.append("REST %s" % oid)

    def market(self, oid, side, qty):
        order = Order(oid, side, 0, qty)
        self.orders[oid] = order
        rem = self.match(order, None)
        if rem == 0:
            self.out.append("FILLED %s" % oid)
        else:
            self.out.append("CANCEL %s %d" % (oid, rem))

    def cancel(self, oid):
        order = self.orders.get(oid)
        if order is None or not order.resting:
            self.out.append("REJECT %s" % oid)
            return
        self.unrest(order)
        self.out.append("CANCEL %s %d" % (oid, order.rem))

    def replace(self, oid, price, qty):
        order = self.orders.get(oid)
        if order is None or not order.resting:
            self.out.append("REJECT %s" % oid)
            return
        if price == order.price and qty <= order.rem:
            level = self.sides[order.side].levels[price]
            level[1] -= order.rem - qty
            order.rem = qty
            self.out.append("REST %s" % oid)
            return
        self.unrest(order)
        self.limit(oid, order.side, price, qty, None)

    def print_book(self):
        out = self.out
        bids, asks = self.sides
        for key in reversed(bids.keys):
            level = bids.levels[key]
            out.append("BID %d %d %d" % (key, level[1], level[2]))
        for key in reversed(asks.keys):
            level = asks.levels[-key]
            out.append("ASK %d %d %d" % (-key, level[1], level[2]))
        out.append("--")


def main():
    data = sys.stdin.buffer.read().decode("utf-8")
    lines = data.split("\n")
    n = int(lines[0].strip())
    out = []
    book = Book(out)
    for i in range(1, n + 1):
        parts = lines[i].split()
        cmd = parts[0]
        if cmd == "LIMIT":
            side = BID if parts[2] == "BUY" else ASK
            flag = parts[5] if len(parts) > 5 else None
            book.limit(parts[1], side, int(parts[3]), int(parts[4]), flag)
        elif cmd == "MARKET":
            side = BID if parts[2] == "BUY" else ASK
            book.market(parts[1], side, int(parts[3]))
        elif cmd == "CANCEL":
            book.cancel(parts[1])
        elif cmd == "REPLACE":
            book.replace(parts[1], int(parts[2]), int(parts[3]))
        elif cmd == "BOOK":
            book.print_book()
        else:
            raise ValueError("unknown command: %r" % lines[i])
    if out:
        sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
