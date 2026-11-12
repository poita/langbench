"""Events emitted by the order book.

Every command produces one or more events. Each event renders, via ``str()``,
as exactly the output line defined by the wire format (without the newline).
"""

from __future__ import annotations

import enum
from typing import NamedTuple


class Side(enum.IntEnum):
    """Side of the book an order belongs to."""

    BUY = 0
    SELL = 1


class Trade(NamedTuple):
    """A fill between the incoming (taker) order and a resting (maker) order."""

    taker: str
    maker: str
    price: int
    qty: int

    def __str__(self) -> str:
        return f"TRADE {self.taker} {self.maker} {self.price} {self.qty}"


class Rest(NamedTuple):
    """The order now rests in the book."""

    id: str

    def __str__(self) -> str:
        return f"REST {self.id}"


class Cancelled(NamedTuple):
    """The order left the book (or never entered it) with ``qty`` unfilled."""

    id: str
    qty: int

    def __str__(self) -> str:
        return f"CANCEL {self.id} {self.qty}"


class Rejected(NamedTuple):
    """The command was refused; nothing changed."""

    id: str

    def __str__(self) -> str:
        return f"REJECT {self.id}"


class Filled(NamedTuple):
    """The order's remaining quantity reached zero."""

    id: str

    def __str__(self) -> str:
        return f"FILLED {self.id}"


class BookLevel(NamedTuple):
    """One non-empty price level in a book listing."""

    side: Side
    price: int
    qty: int
    orders: int

    def __str__(self) -> str:
        label = "BID" if self.side == Side.BUY else "ASK"
        return f"{label} {self.price} {self.qty} {self.orders}"


class BookEnd(NamedTuple):
    """Terminator of a book listing."""

    def __str__(self) -> str:
        return "--"


Event = Trade | Rest | Cancelled | Rejected | Filled | BookLevel | BookEnd
