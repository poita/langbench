import pytest

from orderbook import (
    BookEnd, BookLevel, Cancelled, Filled, OrderBook, Rejected, Rest, Side,
    TimeInForce, Trade,
)


def lines(events):
    return [str(e) for e in events]


@pytest.fixture
def book():
    return OrderBook()


def test_rest_and_snapshot(book):
    assert book.limit("b1", Side.BUY, 100, 5) == [Rest("b1")]
    assert book.limit("s1", Side.SELL, 105, 7) == [Rest("s1")]
    assert book.snapshot() == [
        BookLevel(Side.BUY, 100, 5, 1),
        BookLevel(Side.SELL, 105, 7, 1),
    ]
    assert len(book) == 2 and "b1" in book


def test_trade_at_maker_price_and_price_improvement(book):
    book.limit("s1", Side.SELL, 101, 5)
    book.limit("s2", Side.SELL, 103, 5)
    assert lines(book.limit("b1", Side.BUY, 110, 7)) == [
        "TRADE b1 s1 101 5", "FILLED s1", "TRADE b1 s2 103 2", "FILLED b1",
    ]
    assert book.snapshot() == [BookLevel(Side.SELL, 103, 3, 1)]


def test_fifo_within_level(book):
    for i in range(3):
        book.limit(f"b{i}", Side.BUY, 100, 5)
    ev = book.limit("s", Side.SELL, 100, 7)
    assert lines(ev) == ["TRADE s b0 100 5", "FILLED b0", "TRADE s b1 100 2", "FILLED s"]
    assert book.snapshot() == [BookLevel(Side.BUY, 100, 8, 2)]


def test_ioc(book):
    assert book.limit("b", Side.BUY, 100, 4, TimeInForce.IOC) == [Cancelled("b", 4)]
    book.limit("s", Side.SELL, 100, 3)
    assert lines(book.limit("b2", Side.BUY, 100, 4, TimeInForce.IOC)) == [
        "TRADE b2 s 100 3", "FILLED s", "CANCEL b2 1",
    ]
    assert "b2" not in book


def test_fok(book):
    book.limit("s1", Side.SELL, 100, 3)
    book.limit("s2", Side.SELL, 101, 3)
    assert book.limit("b", Side.BUY, 101, 7, TimeInForce.FOK) == [Rejected("b")]
    assert book.limit("b", Side.BUY, 100, 4, TimeInForce.FOK) == [Rejected("b")]
    assert len(book) == 2
    assert lines(book.limit("b", Side.BUY, 101, 6, TimeInForce.FOK))[-1] == "FILLED b"
    assert len(book) == 0


def test_market(book):
    assert book.market("m", Side.BUY, 5) == [Cancelled("m", 5)]
    book.limit("s", Side.SELL, 50, 2)
    assert lines(book.market("m2", Side.BUY, 5)) == [
        "TRADE m2 s 50 2", "FILLED s", "CANCEL m2 3",
    ]


def test_cancel_cases(book):
    book.limit("b", Side.BUY, 10, 5)
    assert book.cancel("b") == [Cancelled("b", 5)]
    assert book.cancel("b") == [Rejected("b")]
    assert book.cancel("never") == [Rejected("never")]
    assert book.snapshot() == []


def test_cancel_from_middle_of_queue(book):
    for i in range(3):
        book.limit(f"b{i}", Side.BUY, 10, 1 + i)
    book.cancel("b1")
    assert book.snapshot() == [BookLevel(Side.BUY, 10, 4, 2)]
    assert lines(book.limit("s", Side.SELL, 10, 4))[0::2][:2] == [
        "TRADE s b0 10 1", "TRADE s b2 10 3",
    ]


def test_replace_keeps_priority_when_quantity_drops(book):
    book.limit("b1", Side.BUY, 10, 5)
    book.limit("b2", Side.BUY, 10, 5)
    assert book.replace("b1", 10, 2) == [Rest("b1")]
    assert book.snapshot() == [BookLevel(Side.BUY, 10, 7, 2)]
    assert lines(book.limit("s", Side.SELL, 10, 1))[0] == "TRADE s b1 10 1"


def test_replace_loses_priority(book):
    book.limit("b1", Side.BUY, 10, 5)
    book.limit("b2", Side.BUY, 10, 5)
    assert book.replace("b1", 10, 6) == [Rest("b1")]
    assert lines(book.limit("s", Side.SELL, 10, 1))[0] == "TRADE s b2 10 1"


def test_replace_aggressive_and_original_side(book):
    book.limit("b1", Side.BUY, 100, 10)
    book.limit("s1", Side.SELL, 105, 4)
    assert lines(book.replace("b1", 105, 6)) == [
        "TRADE b1 s1 105 4", "FILLED s1", "REST b1",
    ]
    assert book.snapshot() == [BookLevel(Side.BUY, 105, 2, 1)]
    assert book.cancel("b1") == [Cancelled("b1", 2)]


def test_replace_unknown_rejected(book):
    assert book.replace("x", 1, 1) == [Rejected("x")]


def test_partial_fill_then_replace_uses_remaining(book):
    book.limit("b", Side.BUY, 10, 10)
    book.limit("s", Side.SELL, 10, 4)
    assert book.replace("b", 10, 6) == [Rest("b")]  # equal to remaining


def test_large_quantities_do_not_overflow(book):
    for i in range(10):
        book.limit(f"b{i}", Side.BUY, 7, 10**9)
    assert book.snapshot() == [BookLevel(Side.BUY, 7, 10**10, 10)]
    assert book.limit("f", Side.SELL, 7, 10**9, TimeInForce.FOK)[-1] == Filled("f")


def test_execute_book_query(book):
    from orderbook import BookQuery
    assert book.execute(BookQuery()) == [BookEnd()]


def test_invalid_arguments(book):
    with pytest.raises(ValueError):
        book.limit("a", Side.BUY, 0, 1)
    with pytest.raises(ValueError):
        book.market("a", Side.BUY, 0)
    with pytest.raises(ValueError):
        book.replace("a", 1, 0)


def test_level_recreated_after_removal(book):
    for _ in range(3):
        book.limit("x%d" % len(book), Side.SELL, 5, 1)
        book.market("m", Side.BUY, 1)
    book.limit("a", Side.SELL, 5, 1)
    book.limit("b", Side.SELL, 3, 1)
    assert [l.price for l in book.snapshot()] == [3, 5]
