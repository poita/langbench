/// Unit tests for the buffer, field grammar, heap and secret modules.
module tests.support_test;

import webhooks;

private const(ubyte)[] bytes(string s)
{
    return asBytes(s);
}

unittest
{
    OutBuffer b;
    b.put("ab");
    b.put(cast(ubyte) 'c');
    b.putInt(-120);
    b.putInt(0);
    b.putInt(1_000_000_000_000_000);
    assert(b.toString() == "abc-12001000000000000000");
    assert(b.length == b.data.length);
    b.clear();
    assert(b.length == 0);
}

unittest
{
    OutBuffer b;
    foreach (i; 0 .. 10_000)
        b.put("xy");
    assert(b.length == 20_000 && b.data[19_999] == 'y');
}

unittest
{
    long v;
    foreach (ok; ["0", "5", "-5", "1614265330", "1000000000000000", "-1000000000000000", "10"])
        assert(parseCanonicalInt(bytes(ok), v), ok);
    foreach (bad; ["", "-", "-0", "+5", "007", "01", "1.0", "1e3", "1000000000000001",
            "-1000000000000001", "12345678901234567", " 1", "1 ", "0x1", "--1"])
        assert(!parseCanonicalInt(bytes(bad), v), bad);
    assert(parseCanonicalInt(bytes("-42"), v) && v == -42);
}

unittest
{
    assert(isMessageId(bytes("-")));
    assert(isMessageId(bytes("msg_p5jXN8AQM9LWM0D4loKWxJek")));
    assert(!isMessageId(bytes("")));
    assert(!isMessageId(bytes("a b")));
    assert(!isMessageId(bytes("a\tb")));
    assert(!isMessageId(bytes("caf\xc3\xa9")));
    auto long256 = new ubyte[256];
    long256[] = 'a';
    assert(isMessageId(long256));
    assert(!isMessageId(long256 ~ cast(ubyte) 'a'));

    assert(isName(bytes("user.created")) && isName(bytes("A_b-1.x")));
    assert(!isName(bytes("")) && !isName(bytes("a b")) && !isName(bytes("a,b")) && !isName(bytes("a*")));
    auto long65 = new ubyte[65];
    long65[] = 'a';
    assert(!isName(long65) && isName(long65[1 .. $]));
}

unittest
{
    Bytes[] storage;
    auto p = splitOn(bytes("a,,b,"), ',', storage);
    assert(p.length == 4 && p[0] == bytes("a") && p[1].length == 0 && p[2] == bytes("b") && p[3].length == 0);
    p = splitOn(bytes(""), ',', storage);
    assert(p.length == 1 && p[0].length == 0);
    p = splitOn(bytes("x"), ',', storage);
    assert(p.length == 1 && p[0] == bytes("x"));
    assert(isBlank(bytes("")) && isBlank(bytes("   ")) && !isBlank(bytes(" \t")) && !isBlank(bytes(" a")));
}

unittest
{
    auto h = MinHeap(2);
    assert(h.empty);
    uint next = 0;
    foreach (t; [5L, 1, 4, 1, 9, 0, 3])
        h.push(TimedItem(t, next++));
    assert(h.length == 7);
    long lastT = -1;
    uint lastId = 0;
    while (!h.empty)
    {
        auto it = h.pop();
        assert(it.time > lastT || (it.time == lastT && it.id > lastId));
        lastT = it.time;
        lastId = it.id;
    }
}

unittest
{
    TimedItem[] items;
    foreach (i; 0 .. 500)
        items ~= TimedItem((i * 7919) % 101, cast(uint) i);
    auto h = MinHeap.heapify(items);
    assert(h.length == 500);
    TimedItem prev = h.pop();
    while (!h.empty)
    {
        auto cur = h.pop();
        assert(prev.time < cur.time || (prev.time == cur.time && prev.id < cur.id));
        prev = cur;
    }
}

unittest
{
    ubyte[] key;
    assert(decodeSecret(bytes("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"), key));
    assert(toHex(key) == "31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0");
    ubyte[] key2;
    assert(decodeSecret(bytes("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"), key2) && key2 == key);
    assert(decodeSecret(bytes("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr"), key2) && key2.length == 25);
    // The prefix is removed only once; the second one is Base64 data (6 characters -> 4 bytes).
    assert(decodeSecret(bytes("whsec_whsec_"), key) && key.length == 4);
    assert(!decodeSecret(bytes("whsec_"), key)); // decodes to zero bytes
    assert(!decodeSecret(bytes("a"), key)); // invalid length
    assert(!decodeSecret(bytes("ab,c"), key));
    assert(!decodeSecret(bytes("ab cd"), key));
    assert(!decodeSecret(bytes(""), key));
}

unittest
{
    HmacKey[] keys;
    assert(parseSecrets(bytes("whsec_c2VjcmV0,whsec_b3RoZXI"), keys) && keys.length == 2);
    assert(!parseSecrets(bytes("whsec_c2VjcmV0,"), keys));
    assert(!parseSecrets(bytes(",whsec_c2VjcmV0"), keys));
    assert(!parseSecrets(bytes("whsec_c2VjcmV0,x"), keys));
    string sixteen = "c2VjcmV0";
    foreach (_; 0 .. 15)
        sixteen ~= ",c2VjcmV0";
    assert(parseSecrets(bytes(sixteen), keys) && keys.length == 16);
    assert(!parseSecrets(bytes(sixteen ~ ",c2VjcmV0"), keys));
}
