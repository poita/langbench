module tests.pricetable_test;

import orderbook.pricetable;
import orderbook.types;

unittest // sort, dedupe, rank
{
    auto t = PriceTable.from([30, 10, 20, 10, 30, 1_000_000_000]);
    assert(t.length == 4);
    assert(t.priceOf(0) == 10 && t.priceOf(3) == 1_000_000_000);
    assert(t.rankOf(20) == 1);
    assert(t.contains(30) && !t.contains(25));
}

unittest // empty table
{
    auto t = PriceTable.from([]);
    assert(t.length == 0 && !t.contains(1));
}

unittest // ranks are assigned to LIMIT and REPLACE only
{
    Command[] cs = [Command(0, 50, 1, 0, CmdKind.limit), Command(0, 0, 0, 7, CmdKind.cancel),
        Command(0, 40, 1, 0, CmdKind.replace)];
    auto t = PriceTable.from([50, 40]);
    t.assignRanks(cs);
    assert(cs[0].rank == 1 && cs[1].rank == 7 && cs[2].rank == 0);
}
