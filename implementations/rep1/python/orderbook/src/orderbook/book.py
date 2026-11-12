"""The limit order book and its matching engine.

Data structures
---------------
* Each side keeps a dict ``price -> _Level`` plus a sorted list of *keys*
  (``price`` for bids, ``-price`` for asks) in ascending order, so the best
  level is always the last element: it is found and removed in O(1), and
  levels are inserted/removed with ``bisect`` (a binary search plus a small
  memmove).  Walking levels best-first (FOK check, BOOK) is a reverse scan.
* A level holds an intrusive doubly linked FIFO list of orders together with
  its total quantity and order count, so removing an order from the middle of
  a queue is O(1) and level totals are always current.
* ``OrderBook._orders`` maps id -> resting order for CANCEL and REPLACE.
"""

from __future__ import annotations

from bisect import bisect_left, insort
from typing import Optional

from .commands import (
    BookQuery,
    Cancel,
    Command,
    Limit,
    Market,
    Replace,
    TimeInForce,
)
from .events import (
    BookEnd,
    BookLevel,
    Cancelled,
    Event,
    Filled,
    Rejected,
    Rest,
    Side,
    Trade,
)

_NO_LIMIT = -(1 << 62)  # threshold key that every level satisfies (MARKET)


class _Order:
    __slots__ = ("id", "side", "price", "qty", "level", "prev", "next")

    def __init__(self, id: str, side: int, price: int, qty: int) -> None:
        self.id = id
        self.side = side
        self.price = price
        self.qty = qty
        self.level: Optional[_Level] = None
        self.prev: Optional[_Order] = None
        self.next: Optional[_Order] = None


class _Level:
    __slots__ = ("price", "total", "count", "head", "tail")

    def __init__(self, price: int) -> None:
        self.price = price
        self.total = 0
        self.count = 0
        self.head: Optional[_Order] = None
        self.tail: Optional[_Order] = None


class _Side:
    """One side of the book: price levels in best-last sorted order."""

    __slots__ = ("sign", "levels", "keys")

    def __init__(self, sign: int) -> None:
        self.sign = sign  # +1 bids (higher is better), -1 asks (lower is better)
        self.levels: dict[int, _Level] = {}
        self.keys: list[int] = []

    def append(self, order: _Order) -> None:
        """Add ``order`` at the back of its price level's queue."""
        price = order.price
        level = self.levels.get(price)
        if level is None:
            level = self.levels[price] = _Level(price)
            insort(self.keys, price * self.sign)
        order.level = level
        tail = level.tail
        order.prev = tail
        order.next = None
        if tail is None:
            level.head = order
        else:
            tail.next = order
        level.tail = order
        level.total += order.qty
        level.count += 1

    def unlink(self, order: _Order) -> None:
        """Remove ``order`` from its level (dropping the level if emptied)."""
        level = order.level
        prev, nxt = order.prev, order.next
        if prev is None:
            level.head = nxt
        else:
            prev.next = nxt
        if nxt is None:
            level.tail = prev
        else:
            nxt.prev = prev
        order.prev = order.next = order.level = None
        level.total -= order.qty
        level.count -= 1
        if level.count == 0:
            self._drop_level(level)

    def _drop_level(self, level: _Level) -> None:
        del self.levels[level.price]
        keys = self.keys
        key = level.price * self.sign
        if keys and keys[-1] == key:
            keys.pop()
        else:
            del keys[bisect_left(keys, key)]


class OrderBook:
    """A single-instrument limit order book with price-time priority.

    Every mutating method returns the list of events the command produced,
    in output order.  ``str(event)`` gives the wire-format line.
    """

    def __init__(self) -> None:
        self._sides = (_Side(1), _Side(-1))  # indexed by Side: BUY, SELL
        self._orders: dict[str, _Order] = {}

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def limit(
        self,
        order_id: str,
        side: Side,
        price: int,
        qty: int,
        tif: TimeInForce = TimeInForce.GTC,
    ) -> list[Event]:
        """Submit a limit order (plain, IOC or FOK)."""
        if price < 1 or qty < 1:
            raise ValueError("price and qty must be positive")
        side = int(side)
        events: list[Event] = []
        opp = self._sides[1 - side]
        threshold = opp.sign * price
        if tif is TimeInForce.FOK and self._available(opp, threshold) < qty:
            return [Rejected(order_id)]
        remaining = self._match(order_id, opp, threshold, qty, events)
        if remaining == 0:
            events.append(Filled(order_id))
        elif tif is TimeInForce.GTC:
            self._rest(order_id, side, price, remaining)
            events.append(Rest(order_id))
        else:  # IOC (FOK cannot have a remainder)
            events.append(Cancelled(order_id, remaining))
        return events

    def market(self, order_id: str, side: Side, qty: int) -> list[Event]:
        """Submit a market order; any unfilled remainder is cancelled."""
        if qty < 1:
            raise ValueError("qty must be positive")
        events: list[Event] = []
        opp = self._sides[1 - int(side)]
        remaining = self._match(order_id, opp, _NO_LIMIT, qty, events)
        if remaining == 0:
            events.append(Filled(order_id))
        else:
            events.append(Cancelled(order_id, remaining))
        return events

    def cancel(self, order_id: str) -> list[Event]:
        """Cancel a resting order, or reject if it is not resting."""
        order = self._orders.pop(order_id, None)
        if order is None:
            return [Rejected(order_id)]
        qty = order.qty
        self._sides[order.side].unlink(order)
        return [Cancelled(order_id, qty)]

    def replace(self, order_id: str, price: int, qty: int) -> list[Event]:
        """Modify a resting order's price and remaining quantity.

        Keeps queue priority only if the price is unchanged and the quantity
        does not increase; otherwise the order re-enters as a new limit order.
        """
        if price < 1 or qty < 1:
            raise ValueError("price and qty must be positive")
        order = self._orders.get(order_id)
        if order is None:
            return [Rejected(order_id)]
        if price == order.price and qty <= order.qty:
            order.level.total += qty - order.qty
            order.qty = qty
            return [Rest(order_id)]
        del self._orders[order_id]
        self._sides[order.side].unlink(order)
        return self.limit(order_id, Side(order.side), price, qty)

    def snapshot(self) -> list[BookLevel]:
        """All non-empty levels: bids best-first, then asks best-first."""
        out: list[BookLevel] = []
        for side in (Side.BUY, Side.SELL):
            s = self._sides[side]
            levels = s.levels
            for key in reversed(s.keys):
                lv = levels[key * s.sign]
                out.append(BookLevel(side, lv.price, lv.total, lv.count))
        return out

    def execute(self, command: Command) -> list[Event]:
        """Execute a parsed command and return its events."""
        if isinstance(command, Limit):
            return self.limit(*command)
        if isinstance(command, Market):
            return self.market(*command)
        if isinstance(command, Cancel):
            return self.cancel(command.id)
        if isinstance(command, Replace):
            return self.replace(*command)
        if isinstance(command, BookQuery):
            return [*self.snapshot(), BookEnd()]
        raise TypeError(f"unknown command: {command!r}")

    def __contains__(self, order_id: str) -> bool:
        return order_id in self._orders

    def __len__(self) -> int:
        """Number of resting orders."""
        return len(self._orders)

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    @staticmethod
    def _available(opp: _Side, threshold: int) -> int:
        """Total resting quantity on ``opp`` at levels satisfying ``threshold``."""
        total = 0
        levels = opp.levels
        sign = opp.sign
        for key in reversed(opp.keys):
            if key < threshold:
                break
            total += levels[key * sign].total
        return total

    def _rest(self, order_id: str, side: int, price: int, qty: int) -> None:
        order = _Order(order_id, side, price, qty)
        self._orders[order_id] = order
        self._sides[side].append(order)

    def _match(
        self,
        taker: str,
        opp: _Side,
        threshold: int,
        qty: int,
        events: list[Event],
    ) -> int:
        """Match an incoming order against ``opp``; return the unfilled qty."""
        keys = opp.keys
        levels = opp.levels
        sign = opp.sign
        orders = self._orders
        while qty and keys and keys[-1] >= threshold:
            level = levels[keys[-1] * sign]
            price = level.price
            maker = level.head
            while maker is not None and qty:
                mqty = maker.qty
                t = qty if qty < mqty else mqty
                qty -= t
                events.append(Trade(taker, maker.id, price, t))
                if t == mqty:
                    nxt = maker.next
                    del orders[maker.id]
                    # Fully consumed: drop from the level (list head removal).
                    level.head = nxt
                    if nxt is None:
                        level.tail = None
                    else:
                        nxt.prev = None
                    level.total -= t
                    level.count -= 1
                    maker.prev = maker.next = maker.level = None
                    events.append(Filled(maker.id))
                    maker = nxt
                else:
                    maker.qty = mqty - t
                    level.total -= t
            if level.count == 0:
                del levels[price]
                keys.pop()
        return qty
