/// The header page (page 1) and the index directory (SPEC §7, §8).
module tessera.header;

import tessera.bytes;
import tessera.constants;

/// One slot of the index directory.
struct IndexSlot
{
    /// Whether the slot describes a live index.
    bool live;
    /// Length of the path text in bytes.
    ubyte pathLen;
    /// The path text, zero padded.
    ubyte[MAX_PATH] pathBytes;
    /// Root page of the index tree, 0 when empty.
    uint root;
    /// Number of entries in the index.
    uint entries;

    /// The path text of a live index.
    string pathText() const @safe pure nothrow
    {
        return (cast(const(char)[]) pathBytes[0 .. pathLen]).idup;
    }
}

/// Decoded contents of page 1.
struct Header
{
    uint pageCount = 1;
    uint freelistHead;
    uint freelistCount;
    uint primaryRoot;
    uint primaryCount;
    ulong commitCounter;
    uint indexCount;
    IndexSlot[MAX_INDEXES] slots;

    /// The header of a freshly initialised database (SPEC §7.3).
    static Header fresh() @safe pure nothrow
    {
        return Header.init;
    }

    /// The canonical 1024 bytes of page 1.
    ubyte[] encode() const @safe pure nothrow
    {
        auto p = new ubyte[PAGE_SIZE];
        p[0 .. 8] = cast(const(ubyte)[]) "TESSERA1";
        putU16(p, 8, 1);
        putU16(p, 10, PAGE_SIZE);
        putU32(p, 12, pageCount);
        putU32(p, 16, freelistHead);
        putU32(p, 20, freelistCount);
        putU32(p, 24, primaryRoot);
        putU32(p, 28, primaryCount);
        putU64(p, 32, commitCounter);
        putU32(p, 40, indexCount);
        foreach (i, ref s; slots)
        {
            if (!s.live)
                continue;
            immutable o = 128 + 48 * i;
            p[o] = 1;
            p[o + 1] = s.pathLen;
            p[o + 2 .. o + 2 + MAX_PATH] = s.pathBytes[];
            putU32(p, o + 32, s.root);
            putU32(p, o + 36, s.entries);
        }
        return p;
    }

    /// Decode page 1.
    static Header decode(const(ubyte)[] p) @safe pure nothrow
    {
        Header h;
        h.pageCount = getU32(p, 12);
        h.freelistHead = getU32(p, 16);
        h.freelistCount = getU32(p, 20);
        h.primaryRoot = getU32(p, 24);
        h.primaryCount = getU32(p, 28);
        h.commitCounter = getU64(p, 32);
        h.indexCount = getU32(p, 40);
        foreach (i, ref s; h.slots)
        {
            immutable o = 128 + 48 * i;
            if (p[o] != 1)
                continue;
            s.live = true;
            s.pathLen = p[o + 1];
            s.pathBytes[] = p[o + 2 .. o + 2 + MAX_PATH];
            s.root = getU32(p, o + 32);
            s.entries = getU32(p, o + 36);
        }
        return h;
    }
}

@safe pure nothrow unittest
{
    // SPEC §7.3: the fresh header page
    auto p = Header.fresh().encode();
    assert(p.length == 1024);
    assert(p[0 .. 16] == cast(const(ubyte)[]) "TESSERA1\x00\x01\x04\x00\x00\x00\x00\x01");
    foreach (b; p[16 .. $])
        assert(b == 0);

    // SPEC §7.2: a committed single-document database
    Header h;
    h.pageCount = 2;
    h.primaryRoot = 2;
    h.primaryCount = 1;
    h.commitCounter = 1;
    auto q = h.encode();
    assert(q[12 .. 16] == [0, 0, 0, 2]);
    assert(q[24 .. 28] == [0, 0, 0, 2]);
    assert(q[39] == 1);
    assert(Header.decode(q).encode() == q);
}

@safe pure nothrow unittest
{
    // SPEC §8: a slot with an index on `age`, root page 4, one entry
    Header h;
    h.indexCount = 1;
    h.slots[0].live = true;
    h.slots[0].pathLen = 3;
    h.slots[0].pathBytes[0 .. 3] = cast(const(ubyte)[]) "age";
    h.slots[0].root = 4;
    h.slots[0].entries = 1;
    auto p = h.encode();
    assert(p[128 .. 133] == [1, 3, 'a', 'g', 'e']);
    assert(p[160 .. 168] == [0, 0, 0, 4, 0, 0, 0, 1]);
    assert(Header.decode(p).slots[0].pathText == "age");
}
