"""Command objects and the parser for the textual command format."""

from __future__ import annotations

import enum
from typing import NamedTuple

from .events import Side


class TimeInForce(enum.Enum):
    """How a limit order treats any quantity left after matching."""

    GTC = "GTC"  #: remainder rests in the book (plain LIMIT)
    IOC = "IOC"  #: remainder is cancelled
    FOK = "FOK"  #: all-or-nothing: rejected unless fully fillable


class Limit(NamedTuple):
    id: str
    side: Side
    price: int
    qty: int
    tif: TimeInForce = TimeInForce.GTC


class Market(NamedTuple):
    id: str
    side: Side
    qty: int


class Cancel(NamedTuple):
    id: str


class Replace(NamedTuple):
    id: str
    price: int
    qty: int


class BookQuery(NamedTuple):
    """The ``BOOK`` command."""


Command = Limit | Market | Cancel | Replace | BookQuery

_SIDES = {"BUY": Side.BUY, "SELL": Side.SELL}
_TIFS = {"IOC": TimeInForce.IOC, "FOK": TimeInForce.FOK}


def parse_command(line: str) -> Command:
    """Parse one command line (without its newline).

    Tokens are identified purely by position, so an order id may equal a
    keyword. Raises :class:`ValueError` on malformed input.
    """
    parts = line.split(" ")
    try:
        verb = parts[0]
        n = len(parts)
        if verb == "LIMIT" and n in (5, 6):
            tif = _TIFS[parts[5]] if n == 6 else TimeInForce.GTC
            return Limit(parts[1], _SIDES[parts[2]], int(parts[3]), int(parts[4]), tif)
        if verb == "MARKET" and n == 4:
            return Market(parts[1], _SIDES[parts[2]], int(parts[3]))
        if verb == "CANCEL" and n == 2:
            return Cancel(parts[1])
        if verb == "REPLACE" and n == 4:
            return Replace(parts[1], int(parts[2]), int(parts[3]))
        if verb == "BOOK" and n == 1:
            return BookQuery()
    except KeyError:
        pass
    raise ValueError(f"malformed command: {line!r}")
