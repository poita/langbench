"""A limit order book matching engine with price-time priority.

Quick start::

    >>> from orderbook import OrderBook, Side
    >>> book = OrderBook()
    >>> [str(e) for e in book.limit("s1", Side.SELL, 101, 5)]
    ['REST s1']
    >>> [str(e) for e in book.limit("b1", Side.BUY, 102, 3)]
    ['TRADE b1 s1 101 3', 'FILLED b1']
"""

from .book import OrderBook
from .commands import (
    BookQuery,
    Cancel,
    Command,
    Limit,
    Market,
    Replace,
    TimeInForce,
    parse_command,
)
from .engine import parse_stream, process, run
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

__all__ = [
    "OrderBook",
    "Side",
    "TimeInForce",
    "Command",
    "Limit",
    "Market",
    "Cancel",
    "Replace",
    "BookQuery",
    "parse_command",
    "parse_stream",
    "process",
    "run",
    "Event",
    "Trade",
    "Rest",
    "Cancelled",
    "Rejected",
    "Filled",
    "BookLevel",
    "BookEnd",
]

__version__ = "1.0.0"
