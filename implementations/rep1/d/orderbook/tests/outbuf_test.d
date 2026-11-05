module tests.outbuf_test;

import orderbook.outbuf;

unittest // integers and strings
{
    OutBuf o;
    o.put("N ");
    o.putUint(0);
    o.putSpaceUint(1234567890123UL);
    o.putSpaceUint(ulong.max);
    o.put('\n');
    assert(cast(const(char)[]) o.data == "N 0 1234567890123 18446744073709551615\n");
}

unittest // growth past the initial capacity, clear and reuse
{
    OutBuf o;
    foreach (i; 0 .. 5000)
        o.put("abcdefghij");
    assert(o.length == 50_000);
    o.clear();
    assert(o.length == 0);
    o.put("x");
    assert(cast(const(char)[]) o.data == "x");
}
