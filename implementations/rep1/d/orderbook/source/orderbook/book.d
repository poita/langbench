/++
`Book`: the matching engine.

A book is created for a fixed `PriceTable` (the set of prices that may occur).
Each side is a dense array of price levels indexed by rank, with a
`LevelTree` over it to find the best level, sum crossing liquidity and walk
the non-empty levels in order. Resting orders live in one arena and form an
intrusive doubly linked FIFO list per level; an `IdMap` finds them by id.

Every operation appends the resulting events, in the textual form defined by
SPEC.md, to an `OutBuf`.

Order ids are borrowed slices: they must stay valid (and unchanged) for as
long as the order may rest in the book.
+/
module orderbook.book;

import orderbook.idmap : IdMap;
import orderbook.leveltree : LevelTree;
import orderbook.outbuf : OutBuf;
import orderbook.pricetable : PriceTable;
import orderbook.types;

/// A price level: FIFO list of orders plus running totals.
private struct Level
{
    int head = nil;
    int tail = nil;
    long total; // sum of remaining quantities
    uint count; // number of orders
}

/// A resting-order record in the arena.
private struct Order
{
    const(char)[] id;
    long rem; // remaining quantity
    int prev = nil;
    int next = nil; // also the free-list link for unused records
    uint rank;
    Side side;
}

/// The limit order book.
struct Book
{
    private PriceTable table;
    private Level[][2] levels; // indexed by Side
    private LevelTree[2] trees;
    private Order[] arena;
    private int freeHead = nil;
    private IdMap ids;

    @disable this(this);

    /// Create an empty book accepting the prices in `table`.
    this(PriceTable table, size_t expectedOrders = 1024)
    {
        this.table = table;
        foreach (s; 0 .. 2)
        {
            levels[s] = new Level[table.length];
            trees[s] = LevelTree(table.length);
        }
        arena.reserve(expectedOrders);
        ids = IdMap(expectedOrders);
    }

    /// The price table this book was built with.
    ref const(PriceTable) priceTable() const return
    {
        return table;
    }

    /// Number of orders currently resting.
    size_t restingOrders() const
    {
        return ids.length;
    }

    // ---- high-level API, in prices ------------------------------------

    /// Submit a limit order; `price` must be in the price table.
    void limit(const(char)[] id, Side side, uint price, uint qty,
        Tif tif, ref OutBuf o)
    {
        doLimit(id, side, table.rankOf(price), qty, tif, o);
    }

    /// Submit a market order.
    void market(const(char)[] id, Side side, uint qty, ref OutBuf o)
    {
        long rem = qty;
        rem = match(id, side, marketLimit(side), rem, o);
        if (rem == 0)
            filledLine(id, o);
        else
            cancelLine(id, rem, o);
    }

    /// Cancel a resting order.
    void cancel(scope const(char)[] id, ref OutBuf o)
    {
        const idx = ids.get(id);
        if (idx < 0)
            return rejectLine(id, o);
        const long rem = arena[idx].rem;
        unlink(idx);
        refresh(arena[idx].side, arena[idx].rank);
        ids.remove(id);
        release(idx);
        o.put("CANCEL ");
        o.put(id);
        o.putSpaceUint(rem);
        o.put('\n');
    }

    /// Modify a resting order; `price` must be in the price table unless the id is not resting.
    void replace(scope const(char)[] id, uint price, uint qty, ref OutBuf o)
    {
        if (ids.get(id) < 0)
            return rejectLine(id, o);
        doReplace(id, table.rankOf(price), qty, o);
    }

    /// Print the book: bids best-first, asks best-first, then `--`.
    void printBook(ref OutBuf o) const
    {
        foreach (side; [Side.buy, Side.sell])
        {
            const bid = side == Side.buy;
            const ref tree = trees[side];
            long r = bid ? tree.highest : tree.lowest;
            while (r >= 0)
            {
                const ref lv = levels[side][r];
                o.put(bid ? "BID " : "ASK ");
                o.putUint(table.priceOf(r));
                o.putSpaceUint(lv.total);
                o.putSpaceUint(lv.count);
                o.put('\n');
                if (bid)
                    r = r == 0 ? -1 : tree.lastAtOrBefore(r - 1);
                else
                    r = tree.firstAtOrAfter(r + 1);
            }
        }
        o.put("--\n");
    }

    /++
    Execute one parsed command. `input` is the buffer the command's id slice
    points into, and `c.rank` must have been assigned.
    +/
    void execute(ref const Command c, scope const(char)[] input, ref OutBuf o)
    {
        const(char)[] id = input[c.idOff .. c.idOff + c.idLen];
        final switch (c.kind)
        {
        case CmdKind.limit:
            doLimit(id, c.side, c.rank, c.qty, c.tif, o);
            break;
        case CmdKind.market:
            // Borrowed id must outlive the order only if it rests; markets never do.
            market(id, c.side, c.qty, o);
            break;
        case CmdKind.cancel:
            cancel(id, o);
            break;
        case CmdKind.replace:
            doReplace(id, c.rank, c.qty, o);
            break;
        case CmdKind.book:
            printBook(o);
            break;
        }
    }

    // ---- internals -----------------------------------------------------

    private int marketLimit(Side side) const
    {
        return side == Side.buy ? cast(int) table.length - 1 : 0;
    }

    private static void filledLine(scope const(char)[] id, ref OutBuf o)
    {
        o.put("FILLED ");
        o.put(id);
        o.put('\n');
    }

    private static void rejectLine(scope const(char)[] id, ref OutBuf o)
    {
        o.put("REJECT ");
        o.put(id);
        o.put('\n');
    }

    private static void cancelLine(scope const(char)[] id, long rem, ref OutBuf o)
    {
        o.put("CANCEL ");
        o.put(id);
        o.putSpaceUint(rem);
        o.put('\n');
    }

    private static void restLine(scope const(char)[] id, ref OutBuf o)
    {
        o.put("REST ");
        o.put(id);
        o.put('\n');
    }

    /// Recompute the tree leaf of one level from the level record.
    private void refresh(Side side, size_t rank)
    {
        const ref lv = levels[side][rank];
        trees[side].set(rank, lv.total, lv.count != 0);
    }

    private int allocate()
    {
        if (freeHead != nil)
        {
            const i = freeHead;
            freeHead = arena[i].next;
            return i;
        }
        arena ~= Order.init;
        return cast(int) arena.length - 1;
    }

    private void release(int idx)
    {
        arena[idx].next = freeHead;
        freeHead = idx;
    }

    /// Detach an order from its level's list and adjust the level totals.
    /// The tree is NOT refreshed.
    private void unlink(int idx)
    {
        auto o = &arena[idx];
        auto lv = &levels[o.side][o.rank];
        if (o.prev != nil)
            arena[o.prev].next = o.next;
        else
            lv.head = o.next;
        if (o.next != nil)
            arena[o.next].prev = o.prev;
        else
            lv.tail = o.prev;
        lv.total -= o.rem;
        lv.count--;
        o.prev = o.next = nil;
    }

    /// Append an order to the back of its level. The tree is NOT refreshed.
    private void append(int idx)
    {
        auto o = &arena[idx];
        auto lv = &levels[o.side][o.rank];
        o.prev = lv.tail;
        o.next = nil;
        if (lv.tail != nil)
            arena[lv.tail].next = idx;
        else
            lv.head = idx;
        lv.tail = idx;
        lv.total += o.rem;
        lv.count++;
    }

    /++
    Match a taker against the opposite side. `limitRank` is the worst
    acceptable rank (inclusive). Returns the taker's remaining quantity.
    +/
    private long match(scope const(char)[] takerId, Side takerSide,
        int limitRank, long rem, ref OutBuf o)
    {
        const buy = takerSide == Side.buy;
        const opp = buy ? Side.sell : Side.buy;
        auto tree = &trees[opp];
        auto lvls = levels[opp];
        while (rem > 0)
        {
            const long best = buy ? tree.lowest : tree.highest;
            if (best < 0 || (buy ? best > limitRank : best < limitRank))
                break;
            auto lv = &lvls[best];
            const price = table.priceOf(best);
            while (rem > 0 && lv.head != nil)
            {
                auto m = &arena[lv.head];
                const t = rem < m.rem ? rem : m.rem;
                o.put("TRADE ");
                o.put(takerId);
                o.put(' ');
                o.put(m.id);
                o.putSpaceUint(price);
                o.putSpaceUint(t);
                o.put('\n');
                rem -= t;
                m.rem -= t;
                lv.total -= t;
                if (m.rem == 0)
                {
                    filledLine(m.id, o);
                    const idx = lv.head;
                    lv.head = m.next;
                    if (m.next != nil)
                        arena[m.next].prev = nil;
                    else
                        lv.tail = nil;
                    lv.count--;
                    ids.remove(m.id);
                    release(idx);
                }
            }
            tree.set(best, lv.total, lv.count != 0);
        }
        return rem;
    }

    private void doLimit(const(char)[] id, Side side, uint rank, uint qty,
        Tif tif, ref OutBuf o)
    {
        long rem = qty;
        if (tif == Tif.fok)
        {
            const avail = side == Side.buy
                ? trees[Side.sell].prefixSum(rank)
                : trees[Side.buy].suffixSum(rank);
            if (avail < rem)
                return rejectLine(id, o);
        }
        rem = match(id, side, cast(int) rank, rem, o);
        if (rem == 0)
            return filledLine(id, o);
        if (tif != Tif.gtc)
            return cancelLine(id, rem, o);
        const idx = allocate();
        arena[idx] = Order(id, rem, nil, nil, rank, side);
        append(idx);
        refresh(side, rank);
        ids.put(id, idx);
        restLine(id, o);
    }

    private void doReplace(scope const(char)[] id, uint rank, uint qty, ref OutBuf o)
    {
        const idx = ids.get(id);
        if (idx < 0)
            return rejectLine(id, o);
        auto ord = &arena[idx];
        const side = ord.side;
        if (rank == ord.rank && qty <= ord.rem)
        {
            levels[side][rank].total -= ord.rem - qty;
            ord.rem = qty;
            refresh(side, rank);
            return restLine(ord.id, o);
        }
        // Priority lost: leave the book, re-enter as a new plain LIMIT.
        const oldRank = ord.rank;
        const(char)[] oid = ord.id;
        unlink(idx);
        refresh(side, oldRank);
        long rem = match(oid, side, cast(int) rank, qty, o);
        if (rem == 0)
        {
            ids.remove(oid);
            release(idx);
            return filledLine(oid, o);
        }
        ord = &arena[idx];
        ord.rank = rank;
        ord.rem = rem;
        append(idx);
        refresh(side, rank);
        restLine(oid, o);
    }
}
