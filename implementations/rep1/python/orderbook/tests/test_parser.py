import pytest

from orderbook import (
    BookQuery, Cancel, Limit, Market, Replace, Side, TimeInForce, parse_command,
    parse_stream,
)


def test_parse_each_command():
    assert parse_command("LIMIT a BUY 10 5") == Limit("a", Side.BUY, 10, 5, TimeInForce.GTC)
    assert parse_command("LIMIT a SELL 10 5 IOC").tif is TimeInForce.IOC
    assert parse_command("LIMIT a SELL 10 5 FOK").tif is TimeInForce.FOK
    assert parse_command("MARKET a SELL 5") == Market("a", Side.SELL, 5)
    assert parse_command("CANCEL a") == Cancel("a")
    assert parse_command("REPLACE a 3 4") == Replace("a", 3, 4)
    assert parse_command("BOOK") == BookQuery()


def test_ids_may_equal_keywords():
    assert parse_command("CANCEL BOOK") == Cancel("BOOK")
    assert parse_command("LIMIT IOC BUY 1 1 IOC").id == "IOC"
    assert parse_command("MARKET BUY BUY 2") == Market("BUY", Side.BUY, 2)


@pytest.mark.parametrize("bad", ["", "NOPE", "LIMIT a BUY 1", "LIMIT a UP 1 1",
                                 "LIMIT a BUY 1 1 GTC", "BOOK x", "CANCEL"])
def test_malformed(bad):
    with pytest.raises(ValueError):
        parse_command(bad)


def test_parse_stream_handles_missing_trailing_newline_and_count():
    assert list(parse_stream("2\nBOOK\nBOOK")) == ["BOOK", "BOOK"]
    assert list(parse_stream("2\nBOOK\nBOOK\n")) == ["BOOK", "BOOK"]
    assert list(parse_stream("0\n")) == []
    assert list(parse_stream("0")) == []
