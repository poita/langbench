module tests.book_test;

import orderbook.book;
import orderbook.outbuf;
import orderbook.pricetable;
import orderbook.types;

private string text(ref OutBuf o)
{
    auto s = cast(string) o.data.idup;
    o.clear();
    return s;
}

private Book makeBook(uint[] prices)
{
    return Book(PriceTable.from(prices.dup));
}

unittest // resting, crossing at the maker's price, FIFO
{
    auto b = makeBook([100, 101, 102]);
    OutBuf o;
    b.limit("s1", Side.sell, 101, 5, Tif.gtc, o);
    b.limit("s2", Side.sell, 101, 5, Tif.gtc, o);
    b.limit("b1", Side.buy, 102, 7, Tif.gtc, o);
    assert(text(o) == "REST s1\nREST s2\nTRADE b1 s1 101 5\nFILLED s1\n"
        ~ "TRADE b1 s2 101 2\nFILLED b1\n");
    b.printBook(o);
    assert(text(o) == "ASK 101 3 1\n--\n");
    assert(b.restingOrders == 1);
}

unittest // IOC and market leftovers are cancelled, never rest
{
    auto b = makeBook([100]);
    OutBuf o;
    b.limit("a", Side.buy, 100, 4, Tif.ioc, o);
    b.market("m", Side.sell, 9, o);
    assert(text(o) == "CANCEL a 4\nCANCEL m 9\n");
    assert(b.restingOrders == 0);
}

unittest // FOK: reject leaves the book untouched, success fills fully
{
    auto b = makeBook([100, 101, 102]);
    OutBuf o;
    b.limit("s1", Side.sell, 100, 3, Tif.gtc, o);
    b.limit("s2", Side.sell, 102, 3, Tif.gtc, o);
    text(o);
    b.limit("f1", Side.buy, 101, 4, Tif.fok, o);
    assert(text(o) == "REJECT f1\n");
    b.limit("f2", Side.buy, 102, 6, Tif.fok, o);
    assert(text(o) == "TRADE f2 s1 100 3\nFILLED s1\nTRADE f2 s2 102 3\nFILLED s2\nFILLED f2\n");
    assert(b.restingOrders == 0);
}

unittest // quantities beyond 32 bits
{
    auto b = makeBook([5]);
    OutBuf o;
    foreach (id; ["a", "b", "c", "d", "e", "f"])
        b.limit(id, Side.sell, 5, 1_000_000_000, Tif.gtc, o);
    o.clear();
    b.printBook(o);
    assert(text(o) == "ASK 5 6000000000 6\n--\n");
    b.limit("k1", Side.buy, 5, 1_000_000_000, Tif.fok, o);
    assert(text(o) == "TRADE k1 a 5 1000000000\nFILLED a\nFILLED k1\n");
}

unittest // cancel and its rejections
{
    auto b = makeBook([10]);
    OutBuf o;
    b.limit("a", Side.buy, 10, 5, Tif.gtc, o);
    b.cancel("a", o);
    b.cancel("a", o);
    b.cancel("zzz", o);
    assert(text(o) == "REST a\nCANCEL a 5\nREJECT a\nREJECT zzz\n");
    b.printBook(o);
    assert(text(o) == "--\n");
}

unittest // replace: priority kept, quantity up, price change, rejected
{
    auto b = makeBook([100, 105, 106, 110]);
    OutBuf o;
    b.limit("b1", Side.buy, 100, 10, Tif.gtc, o);
    b.limit("b2", Side.buy, 100, 10, Tif.gtc, o);
    b.replace("b1", 100, 4, o);      // keeps priority
    b.limit("s1", Side.sell, 100, 5, Tif.gtc, o);
    assert(text(o) == "REST b1\nREST b2\nREST b1\nTRADE s1 b1 100 4\nFILLED b1\n"
        ~ "TRADE s1 b2 100 1\nFILLED s1\n");
    b.replace("b2", 100, 20, o);     // quantity up: re-enters, nothing to trade
    b.replace("b2", 110, 3, o);      // price change
    b.replace("nope", 1, 1, o) ;
    assert(text(o) == "REST b2\nREST b2\nREJECT nope\n");
    b.printBook(o);
    assert(text(o) == "BID 110 3 1\n--\n");
}

unittest // replace that loses priority goes behind its old neighbours
{
    auto b = makeBook([100]);
    OutBuf o;
    b.limit("b1", Side.buy, 100, 5, Tif.gtc, o);
    b.limit("b2", Side.buy, 100, 5, Tif.gtc, o);
    b.replace("b1", 100, 6, o);
    b.limit("s", Side.sell, 100, 5, Tif.gtc, o);
    assert(text(o) == "REST b1\nREST b2\nREST b1\nTRADE s b2 100 5\nFILLED b2\nFILLED s\n");
}

unittest // aggressive replace trades and rests the remainder
{
    auto b = makeBook([100, 105, 106, 110]);
    OutBuf o;
    b.limit("b1", Side.buy, 100, 10, Tif.gtc, o);
    b.limit("s1", Side.sell, 105, 4, Tif.gtc, o);
    b.limit("s2", Side.sell, 106, 4, Tif.gtc, o);
    text(o);
    b.replace("b1", 105, 6, o);
    assert(text(o) == "TRADE b1 s1 105 4\nFILLED s1\nREST b1\n");
    b.replace("b1", 110, 20, o);
    assert(text(o) == "TRADE b1 s2 106 4\nFILLED s2\nREST b1\n");
    b.replace("b1", 110, 3, o);
    b.cancel("b1", o);
    assert(text(o) == "REST b1\nCANCEL b1 3\n");
}

unittest // a replace that fully fills ends the order
{
    auto b = makeBook([100, 101]);
    OutBuf o;
    b.limit("b", Side.buy, 100, 1, Tif.gtc, o);
    b.limit("s", Side.sell, 101, 5, Tif.gtc, o);
    text(o);
    b.replace("b", 101, 5, o);
    assert(text(o) == "TRADE b s 101 5\nFILLED s\nFILLED b\n");
    b.cancel("b", o);
    assert(text(o) == "REJECT b\n");
}

unittest // BOOK lists bids high-to-low then asks low-to-high
{
    auto b = makeBook([1, 2, 3, 4]);
    OutBuf o;
    b.limit("b1", Side.buy, 1, 1, Tif.gtc, o);
    b.limit("b2", Side.buy, 2, 2, Tif.gtc, o);
    b.limit("b3", Side.buy, 2, 3, Tif.gtc, o);
    b.limit("s1", Side.sell, 4, 4, Tif.gtc, o);
    b.limit("s2", Side.sell, 3, 5, Tif.gtc, o);
    text(o);
    b.printBook(o);
    assert(text(o) == "BID 2 5 2\nBID 1 1 1\nASK 3 5 1\nASK 4 4 1\n--\n");
}

unittest // empty price table: only MARKET/CANCEL/BOOK are possible
{
    auto b = makeBook([]);
    OutBuf o;
    b.market("m", Side.buy, 3, o);
    b.cancel("m", o);
    b.printBook(o);
    assert(text(o) == "CANCEL m 3\nREJECT m\n--\n");
}
