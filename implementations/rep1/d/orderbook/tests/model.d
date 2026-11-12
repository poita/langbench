/**
 * Differential test: the engine against a deliberately naive reference
 * implementation (flat array of orders, linear scans) on random streams.
 */
module tests.model;

import std.algorithm : sort, remove;
import std.array : appender;
import std.conv : to;
import std.random : Random, uniform;

import orderbook;

private struct MOrder
{
    string id;
    bool buy;
    long price;
    long qty;
    ulong seq; // arrival order into the book
}

/// Straightforward reference book producing the event lines as strings.
private final class Model
{
    MOrder[] resting;
    ulong clock;
    string[] out_;

    private bool crosses(bool buy, long limit, bool hasLimit, const MOrder m)
    {
        if (m.buy == buy)
            return false;
        return !hasLimit || (buy ? m.price <= limit : m.price >= limit);
    }

    private long match(string id, bool buy, long limit, bool hasLimit, long qty)
    {
        while (qty > 0)
        {
            long best = -1;
            foreach (i, m; resting)
            {
                if (!crosses(buy, limit, hasLimit, m))
                    continue;
                if (best < 0)
                {
                    best = i;
                    continue;
                }
                auto b = resting[best];
                bool better = m.price != b.price ? (buy ? m.price < b.price : m.price > b.price)
                    : m.seq < b.seq;
                if (better)
                    best = i;
            }
            if (best < 0)
                break;
            auto t = qty < resting[best].qty ? qty : resting[best].qty;
            out_ ~= "TRADE " ~ id ~ " " ~ resting[best].id ~ " " ~ resting[best].price.to!string
                ~ " " ~ t.to!string;
            qty -= t;
            resting[best].qty -= t;
            if (resting[best].qty == 0)
            {
                out_ ~= "FILLED " ~ resting[best].id;
                resting = resting.remove(best);
            }
        }
        return qty;
    }

    void limit(string id, bool buy, long price, long qty, string flag)
    {
        if (flag == "FOK")
        {
            long avail;
            foreach (m; resting)
                if (crosses(buy, price, true, m))
                    avail += m.qty;
            if (avail < qty)
            {
                out_ ~= "REJECT " ~ id;
                return;
            }
        }
        auto left = match(id, buy, price, true, qty);
        if (left == 0)
            out_ ~= "FILLED " ~ id;
        else if (flag == "")
        {
            resting ~= MOrder(id, buy, price, left, clock++);
            out_ ~= "REST " ~ id;
        }
        else
            out_ ~= "CANCEL " ~ id ~ " " ~ left.to!string;
    }

    void market(string id, bool buy, long qty)
    {
        auto left = match(id, buy, 0, false, qty);
        out_ ~= left == 0 ? "FILLED " ~ id : "CANCEL " ~ id ~ " " ~ left.to!string;
    }

    private long find(string id)
    {
        foreach (i, m; resting)
            if (m.id == id)
                return i;
        return -1;
    }

    void cancel(string id)
    {
        auto i = find(id);
        if (i < 0)
            { out_ ~= "REJECT " ~ id; return; }
        out_ ~= "CANCEL " ~ id ~ " " ~ resting[i].qty.to!string;
        resting = resting.remove(i);
    }

    void replace(string id, long price, long qty)
    {
        auto i = find(id);
        if (i < 0)
            { out_ ~= "REJECT " ~ id; return; }
        if (price == resting[i].price && qty <= resting[i].qty)
        {
            resting[i].qty = qty;
            { out_ ~= "REST " ~ id; return; }
        }
        bool buy = resting[i].buy;
        resting = resting.remove(i);
        limit(id, buy, price, qty, "");
    }

    void book()
    {
        foreach (buy; [true, false])
        {
            long[] prices;
            foreach (m; resting)
                if (m.buy == buy)
                {
                    bool seen;
                    foreach (p; prices)
                        seen |= p == m.price;
                    if (!seen)
                        prices ~= m.price;
                }
            prices.sort();
            if (buy)
                prices.reverse();
            foreach (p; prices)
            {
                long tot, n;
                foreach (m; resting)
                    if (m.buy == buy && m.price == p)
                    {
                        tot += m.qty;
                        n++;
                    }
                out_ ~= (buy ? "BID " : "ASK ") ~ p.to!string ~ " " ~ tot.to!string ~ " " ~ n.to!string;
            }
        }
        out_ ~= "--";
    }
}

private void reverse(ref long[] a)
{
    foreach (i; 0 .. a.length / 2)
    {
        auto t = a[i];
        a[i] = a[$ - 1 - i];
        a[$ - 1 - i] = t;
    }
}

private string randomStream(ref Random rng, size_t n, long priceSpan, long maxQty)
{
    auto s = appender!string;
    s ~= n.to!string ~ "\n";
    size_t nextId;
    string[] used;
    foreach (_; 0 .. n)
    {
        immutable r = uniform(0, 100, rng);
        string pick()
        {
            // Mostly existing ids, sometimes a never-submitted one.
            if (used.length == 0 || uniform(0, 10, rng) == 0)
                return "ghost" ~ uniform(0, 5, rng).to!string;
            return used[uniform(0, used.length, rng)];
        }

        string side() { return uniform(0, 2, rng) ? "BUY" : "SELL"; }
        long price() { return 100 + uniform(0, priceSpan, rng); }
        long qty() { return uniform(1, maxQty + 1, rng); }

        if (r < 55)
        {
            auto id = "o" ~ (nextId++).to!string;
            used ~= id;
            string flag = r < 40 ? "" : r < 47 ? " IOC" : " FOK";
            s ~= "LIMIT " ~ id ~ " " ~ side() ~ " " ~ price().to!string ~ " " ~ qty().to!string ~ flag ~ "\n";
        }
        else if (r < 62)
        {
            auto id = "o" ~ (nextId++).to!string;
            used ~= id;
            s ~= "MARKET " ~ id ~ " " ~ side() ~ " " ~ qty().to!string ~ "\n";
        }
        else if (r < 77)
            s ~= "CANCEL " ~ pick() ~ "\n";
        else if (r < 92)
            s ~= "REPLACE " ~ pick() ~ " " ~ price().to!string ~ " " ~ qty().to!string ~ "\n";
        else
            s ~= "BOOK\n";
    }
    return s[];
}

private string modelRun(string input)
{
    import std.string : splitLines;

    auto m = new Model;
    auto lines = input.splitLines;
    foreach (line; lines[1 .. $])
    {
        Command c;
        assert(parseCommand(line, c));
        final switch (c.kind)
        {
        case CommandKind.limit:
            m.limit(c.id, c.side == Side.buy, c.price, c.qty,
                    c.tif == TimeInForce.gtc ? "" : c.tif == TimeInForce.ioc ? "IOC" : "FOK");
            break;
        case CommandKind.market:
            m.market(c.id, c.side == Side.buy, c.qty);
            break;
        case CommandKind.cancel:
            m.cancel(c.id);
            break;
        case CommandKind.replace:
            m.replace(c.id, c.price, c.qty);
            break;
        case CommandKind.book:
            m.book();
            break;
        }
    }
    string r;
    foreach (l; m.out_)
        r ~= l ~ "\n";
    return r;
}

unittest
{
    auto rng = Random(12345);
    foreach (iter; 0 .. 300)
    {
        // Vary density: few price levels / small quantities give many collisions.
        auto input = randomStream(rng, 200, iter % 3 == 0 ? 3 : 12, iter % 2 ? 4 : 1_000_000_000);
        auto w = appender!string;
        auto sink = textSink(w);
        processStream(new OrderBook, input, sink);
        auto expected = modelRun(input);
        assert(w[] == expected, "mismatch on stream:\n" ~ input);
    }
}
