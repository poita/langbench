/**
 * The matching engine: a single-instrument limit order book with price-time
 * priority.
 *
 * Every operation reports what happened by calling `put(Event)` on an output
 * range supplied by the caller (an `Appender!(Event[])`, the `TextSink` of
 * `orderbook.format`, or anything else accepted by `isOutputRange!(Sink, Event)`).
 *
 * Data layout
 * $(UL
 *  $(LI Orders live in one pooled array and are linked into a per-level FIFO
 *       queue by index (intrusive doubly-linked list), so removing an order
 *       from the middle of a queue is O(1).)
 *  $(LI Each side keeps its price levels in a red-black tree ordered best
 *       price first, so the best level and removal of an emptied level are
 *       O(log P). Every level stores its total quantity and order count.)
 *  $(LI A hash map from id to pooled order serves `cancel` and `replace`.)
 * )
 */
module orderbook.book;

import std.algorithm.comparison : min;
import std.container.rbtree : RedBlackTree;
import std.range.primitives : isOutputRange;

import orderbook.types;

private enum uint nil = uint.max;

/// Key of the per-side price tree: a price and the index of its `Level`.
private struct PriceKey
{
    Price price;
    uint level;
}

/// A price level: a FIFO queue of orders (by pool index) plus running totals.
private struct Level
{
    Price price;
    uint count;
    Qty total;
    uint head = nil;
    uint tail = nil;
}

/// A resting order. `prev`/`next` link it into its level's queue.
private struct Order
{
    string id;
    Qty remaining;
    Price price;
    Side side;
    uint level;
    uint prev = nil;
    uint next = nil;
}

/// All the price levels of one side, best price first.
private struct BookSide(bool isBid)
{
    // Bids sort descending and asks ascending, so `front` is always the best.
    enum string ordering = isBid ? "a.price > b.price" : "a.price < b.price";
    alias Tree = RedBlackTree!(PriceKey, ordering);

    Tree tree;
    Level[] levels;
    uint[] freeLevels;

    void initialize()
    {
        tree = new Tree;
    }

    bool empty() const
    {
        return tree.empty;
    }

    PriceKey best()
    {
        return tree.front;
    }

    /// Index of the level at `price`, creating it if necessary.
    uint levelAt(Price price)
    {
        auto found = tree.equalRange(PriceKey(price, 0));
        if (!found.empty)
            return found.front.level;

        uint index;
        if (freeLevels.length)
        {
            index = freeLevels[$ - 1];
            freeLevels.length = freeLevels.length - 1;
        }
        else
        {
            index = cast(uint) levels.length;
            levels ~= Level.init;
        }
        levels[index] = Level(price);
        tree.insert(PriceKey(price, index));
        return index;
    }

    /// Drop level `index` from the tree and recycle it (it must be empty).
    void release(uint index)
    {
        assert(levels[index].count == 0);
        tree.removeKey(PriceKey(levels[index].price, index));
        freeLevels ~= index;
    }
}

/**
 * A limit order book.
 *
 * All operations are O(fills + levels visited * log P) plus one id lookup for
 * `cancel` and `replace`, where P is the number of price levels on a side.
 */
final class OrderBook
{
    private
    {
        BookSide!true bids;
        BookSide!false asks;
        Order[] orders;
        uint[] freeOrders;
        uint[string] byId;
    }

    /// Create an empty book.
    this()
    {
        bids.initialize();
        asks.initialize();
    }

    /// Number of orders currently resting.
    size_t restingOrders() const @safe pure nothrow @nogc
    {
        return byId.length;
    }

    /// Whether `id` names a currently resting order.
    bool isResting(string id) const
    {
        return (id in byId) !is null;
    }

    /// Number of non-empty price levels on `side`.
    size_t levelCount(Side side)
    {
        return side == Side.buy ? bids.tree.length : asks.tree.length;
    }

    /**
     * Submit a limit order. Matches against the opposite side, then (for
     * `TimeInForce.gtc`) rests the remainder at the back of its price level.
     *
     * The id must not have been used by an earlier order. The book keeps
     * the `id` slice for as long as the order rests, so it must be immutable
     * data the caller does not mutate (`.idup` it if in doubt).
     */
    void limit(Sink)(string id, Side side, Price price, Qty qty, TimeInForce tif, ref Sink sink)
            if (isOutputRange!(Sink, Event))
    in (qty > 0)
    {
        if (tif == TimeInForce.fok && crossingQuantity(side, price) < qty)
        {
            sink.put(Event.reject(id));
            return;
        }
        Qty left = side == Side.buy
            ? match!true(id, true, price, qty, sink) : match!false(id, true, price, qty, sink);
        finish(id, side, price, left, tif, sink);
    }

    /// Submit a market order: crosses everything, never rests.
    void market(Sink)(string id, Side side, Qty qty, ref Sink sink)
            if (isOutputRange!(Sink, Event))
    in (qty > 0)
    {
        Qty left = side == Side.buy
            ? match!true(id, false, 0, qty, sink) : match!false(id, false, 0, qty, sink);
        if (left == 0)
            sink.put(Event.filled(id));
        else
            sink.put(Event.cancel(id, left));
    }

    /// Cancel a resting order, or reject if `id` is not resting.
    void cancel(Sink)(string id, ref Sink sink)
            if (isOutputRange!(Sink, Event))
    {
        auto p = id in byId;
        if (p is null)
        {
            sink.put(Event.reject(id));
            return;
        }
        immutable remaining = orders[*p].remaining;
        removeResting(*p);
        sink.put(Event.cancel(id, remaining));
    }

    /**
     * Change a resting order's price and remaining quantity. Keeps its queue
     * position iff the price is unchanged and the quantity not increased;
     * otherwise it is removed and re-enters as a plain limit order.
     */
    void replace(Sink)(string id, Price price, Qty qty, ref Sink sink)
            if (isOutputRange!(Sink, Event))
    in (qty > 0)
    {
        auto p = id in byId;
        if (p is null)
        {
            sink.put(Event.reject(id));
            return;
        }
        immutable idx = *p;
        Order* o = &orders[idx];
        if (price == o.price && qty <= o.remaining)
        {
            level(o.side, o.level).total -= o.remaining - qty;
            o.remaining = qty;
            sink.put(Event.rest(id));
            return;
        }
        immutable side = o.side;
        string key = o.id;
        removeResting(idx);
        limit(key, side, price, qty, TimeInForce.gtc, sink);
    }

    /**
     * Emit the book: every bid level best first (`Event.bid`), every ask
     * level best first (`Event.ask`), then `Event.endOfBook`.
     */
    void snapshot(Sink)(ref Sink sink)
            if (isOutputRange!(Sink, Event))
    {
        foreach (k; bids.tree[])
        {
            const l = bids.levels[k.level];
            sink.put(Event.level(Side.buy, l.price, l.total, l.count));
        }
        foreach (k; asks.tree[])
        {
            const l = asks.levels[k.level];
            sink.put(Event.level(Side.sell, l.price, l.total, l.count));
        }
        sink.put(Event.endOfBook());
    }

    // ------------------------------------------------------------------

    private ref Level level(Side side, uint index)
    {
        return side == Side.buy ? bids.levels[index] : asks.levels[index];
    }

    /// Total resting quantity a taker on `side` with limit `price` would cross.
    private Qty crossingQuantity(Side side, Price price)
    {
        return side == Side.buy ? sumCrossing!true(price) : sumCrossing!false(price);
    }

    private Qty sumCrossing(bool takerBuys)(Price limit)
    {
        static if (takerBuys)
            alias opp = asks;
        else
            alias opp = bids;
        Qty sum = 0;
        foreach (k; opp.tree[])
        {
            static if (takerBuys)
                immutable crosses = k.price <= limit;
            else
                immutable crosses = k.price >= limit;
            if (!crosses)
                break;
            sum += opp.levels[k.level].total;
        }
        return sum;
    }

    /// Match a taker against the opposite side; returns its unfilled quantity.
    private Qty match(bool takerBuys, Sink)(string takerId, bool hasLimit, Price limit,
            Qty qty, ref Sink sink)
    {
        static if (takerBuys)
            alias opp = asks;
        else
            alias opp = bids;

        while (qty > 0 && !opp.empty)
        {
            immutable best = opp.best();
            if (hasLimit)
            {
                static if (takerBuys)
                {
                    if (best.price > limit)
                        break;
                }
                else
                {
                    if (best.price < limit)
                        break;
                }
            }
            Level* lv = &opp.levels[best.level];
            while (qty > 0 && lv.head != nil)
            {
                immutable idx = lv.head;
                Order* maker = &orders[idx];
                immutable traded = min(qty, maker.remaining);
                sink.put(Event.trade(takerId, maker.id, best.price, traded));
                qty -= traded;
                maker.remaining -= traded;
                lv.total -= traded;
                if (maker.remaining == 0)
                {
                    sink.put(Event.filled(maker.id));
                    lv.head = maker.next;
                    if (lv.head == nil)
                        lv.tail = nil;
                    else
                        orders[lv.head].prev = nil;
                    lv.count--;
                    byId.remove(maker.id);
                    freeOrder(idx);
                }
            }
            if (lv.count == 0)
                opp.release(best.level);
        }
        return qty;
    }

    /// Emit the taker's final event and rest the remainder if appropriate.
    private void finish(Sink)(string id, Side side, Price price, Qty left, TimeInForce tif,
            ref Sink sink)
    {
        if (left == 0)
            sink.put(Event.filled(id));
        else if (tif == TimeInForce.gtc)
        {
            addResting(id, side, price, left);
            sink.put(Event.rest(id));
        }
        else
            sink.put(Event.cancel(id, left));
    }

    private void addResting(string id, Side side, Price price, Qty qty)
    {
        uint idx;
        if (freeOrders.length)
        {
            idx = freeOrders[$ - 1];
            freeOrders.length = freeOrders.length - 1;
        }
        else
        {
            idx = cast(uint) orders.length;
            orders ~= Order.init;
        }
        uint lvIndex = side == Side.buy ? bids.levelAt(price) : asks.levelAt(price);
        Level* lv = &level(side, lvIndex);
        orders[idx] = Order(id, qty, price, side, lvIndex, lv.tail, nil);
        if (lv.tail == nil)
            lv.head = idx;
        else
            orders[lv.tail].next = idx;
        lv.tail = idx;
        lv.count++;
        lv.total += qty;
        byId[id] = idx;
    }

    /// Unlink a resting order from its level and the id map and recycle it.
    private void removeResting(uint idx)
    {
        Order* o = &orders[idx];
        Level* lv = &level(o.side, o.level);
        if (o.prev == nil)
            lv.head = o.next;
        else
            orders[o.prev].next = o.next;
        if (o.next == nil)
            lv.tail = o.prev;
        else
            orders[o.next].prev = o.prev;
        lv.count--;
        lv.total -= o.remaining;
        if (lv.count == 0)
        {
            if (o.side == Side.buy)
                bids.release(o.level);
            else
                asks.release(o.level);
        }
        byId.remove(o.id);
        freeOrder(idx);
    }

    private void freeOrder(uint idx)
    {
        orders[idx] = Order.init;
        freeOrders ~= idx;
    }
}

version (unittest) import std.array : appender;

unittest
{
    // Matching across levels at the maker's price, FIFO, partial maker fill.
    auto b = new OrderBook;
    auto sink = appender!(Event[]);
    b.limit("s1", Side.sell, 101, 5, TimeInForce.gtc, sink);
    b.limit("s2", Side.sell, 103, 5, TimeInForce.gtc, sink);
    b.limit("s3", Side.sell, 102, 5, TimeInForce.gtc, sink);
    sink.clear();
    b.limit("b1", Side.buy, 103, 12, TimeInForce.gtc, sink);
    string[] got;
    foreach (e; sink[])
        got ~= e.toString;
    assert(got == [
        "TRADE b1 s1 101 5", "FILLED s1", "TRADE b1 s3 102 5", "FILLED s3",
        "TRADE b1 s2 103 2", "FILLED b1"
    ]);
    assert(b.restingOrders == 1);
    assert(b.levelCount(Side.sell) == 1);
}

unittest
{
    // FOK is rejected without side effects, accepted when exactly fillable.
    auto b = new OrderBook;
    auto sink = appender!(Event[]);
    b.limit("a", Side.sell, 10, 4, TimeInForce.gtc, sink);
    b.limit("b", Side.sell, 11, 4, TimeInForce.gtc, sink);
    sink.clear();
    b.limit("f1", Side.buy, 11, 9, TimeInForce.fok, sink);
    assert(sink[].length == 1 && sink[][0].kind == EventKind.reject);
    assert(b.restingOrders == 2);
    sink.clear();
    b.limit("f2", Side.buy, 11, 8, TimeInForce.fok, sink);
    assert(sink[][$ - 1].kind == EventKind.filled && sink[][$ - 1].id == "f2");
    assert(b.restingOrders == 0);
}

unittest
{
    // Quantities beyond 2^32 are summed in 64 bits.
    auto b = new OrderBook;
    auto sink = appender!(Event[]);
    foreach (i; 0 .. 6)
        b.limit(["a", "b", "c", "d", "e", "f"][i], Side.buy, 5, 1_000_000_000, TimeInForce.gtc, sink);
    sink.clear();
    b.snapshot(sink);
    assert(sink[][0].qty == 6_000_000_000 && sink[][0].orders == 6);
}

unittest
{
    // Cancel / replace semantics.
    auto b = new OrderBook;
    auto sink = appender!(Event[]);
    b.limit("x", Side.buy, 10, 5, TimeInForce.gtc, sink);
    b.limit("y", Side.buy, 10, 5, TimeInForce.gtc, sink);
    sink.clear();
    b.replace("x", 10, 3, sink); // keeps priority
    b.replace("x", 10, 4, sink); // increase: goes to the back
    b.limit("s", Side.sell, 10, 5, TimeInForce.ioc, sink);
    string[] got;
    foreach (e; sink[])
        got ~= e.toString;
    assert(got == ["REST x", "REST x", "TRADE s y 10 5", "FILLED y", "FILLED s"]);
    sink.clear();
    b.cancel("x", sink);
    b.cancel("x", sink);
    b.replace("nope", 1, 1, sink);
    assert(sink[][0].toString == "CANCEL x 4");
    assert(sink[][1].toString == "REJECT x");
    assert(sink[][2].toString == "REJECT nope");
}
