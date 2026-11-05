/++
Offline price compression.

All prices that can occur in a stream are collected up front, sorted and
deduplicated. Every price then has a dense *rank*; the matching engine works
purely on ranks, so each side of the book is a plain array indexed by rank.
+/
module orderbook.pricetable;

import std.algorithm.sorting : sort;
import orderbook.types : Command, CmdKind;

/// A sorted, duplicate-free table of prices with rank/price conversion.
struct PriceTable
{
    private uint[] prices_;

    /// Build a table from an arbitrary list of prices (sorted in place).
    static PriceTable from(uint[] prices) @safe
    {
        sort(prices);
        size_t n = 0;
        foreach (i, p; prices)
        {
            if (n == 0 || prices[n - 1] != p)
                prices[n++] = p;
        }
        PriceTable t;
        t.prices_ = prices[0 .. n];
        return t;
    }

    /// Number of distinct prices.
    size_t length() const @safe pure nothrow @nogc
    {
        return prices_.length;
    }

    /// The price with the given rank.
    uint priceOf(size_t rank) const @safe pure nothrow @nogc
    {
        return prices_[rank];
    }

    /// True if `price` is in the table.
    bool contains(uint price) const @safe pure nothrow @nogc
    {
        const r = lowerBound(price);
        return r < prices_.length && prices_[r] == price;
    }

    /// Rank of `price`, which must be in the table (binary search).
    uint rankOf(uint price) const @safe pure nothrow @nogc
    in (contains(price), "price is not in the price table")
    {
        return cast(uint) lowerBound(price);
    }

    private size_t lowerBound(uint price) const @safe pure nothrow @nogc
    {
        size_t lo = 0, hi = prices_.length;
        while (lo < hi)
        {
            const mid = lo + (hi - lo) / 2;
            if (prices_[mid] < price)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo;
    }

    /// Fill in `Command.rank` for every LIMIT and REPLACE command.
    void assignRanks(Command[] commands) const @safe pure nothrow @nogc
    {
        foreach (ref c; commands)
        {
            if (c.kind == CmdKind.limit || c.kind == CmdKind.replace)
                c.rank = rankOf(c.price);
        }
    }
}
