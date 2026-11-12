/// Pack index (`.idx`) version 2 reader.
module gitrepo.packindex;

import gitrepo.errors;
import gitrepo.objectid;

/// A parsed, in-memory pack index.
struct PackIndex
{
    private const(ubyte)[] data;
    private size_t count_;
    private size_t idsAt, offsetsAt, bigOffsetsAt, bigCount;

    /// Parse and sanity-check an index file's bytes (the array is kept, not copied).
    static PackIndex parse(const(ubyte)[] data) @safe pure
    {
        enum fanoutAt = 8;
        enum tableAt = 8 + 1024;
        if (data.length < tableAt + 40 || data[0 .. 4] != cast(immutable(ubyte)[]) "\xfftOc"
                || be32(data, 4) != 2)
            throw new GitError("not a version 2 pack index");
        PackIndex ix;
        ix.data = data;
        ix.count_ = be32(data, fanoutAt + 255 * 4);
        uint prev = 0;
        foreach (i; 0 .. 256)
        {
            immutable v = be32(data, fanoutAt + 4 * i);
            if (v < prev)
                throw new GitError("pack index fanout not monotonic");
            prev = v;
        }
        immutable n = ix.count_;
        immutable fixedSize = tableAt + 28 * n + 40;
        if (data.length < fixedSize || (data.length - fixedSize) % 8 != 0)
            throw new GitError("pack index has wrong size");
        ix.idsAt = tableAt;
        ix.offsetsAt = tableAt + 24 * n;
        ix.bigOffsetsAt = tableAt + 28 * n;
        ix.bigCount = (data.length - fixedSize) / 8;
        return ix;
    }

    /// Number of objects in the index (`fanout[255]`).
    size_t length() const @safe pure nothrow @nogc
    {
        return count_;
    }

    /// The `i`-th id in ascending order.
    ObjectId idAt(size_t i) const @safe pure nothrow @nogc
    {
        ObjectId id;
        id.bytes[] = data[idsAt + 20 * i .. idsAt + 20 * i + 20];
        return id;
    }

    /// Pack offset of the `i`-th object.
    ulong offsetAt(size_t i) const @safe pure
    {
        immutable v = be32(data, offsetsAt + 4 * i);
        if (!(v & 0x8000_0000))
            return v;
        immutable j = v & 0x7fff_ffff;
        if (j >= bigCount)
            throw new GitError("pack index 64-bit offset out of range");
        immutable p = bigOffsetsAt + 8 * j;
        return (cast(ulong) be32(data, p) << 32) | be32(data, p + 4);
    }

    /// Index of the first entry whose id is >= `id` (`length` if none), found by
    /// a binary search inside the fanout bucket of the id's first byte.
    size_t lowerBound(const ObjectId id) const @safe pure nothrow @nogc
    {
        immutable b = id.bytes[0];
        size_t lo = b == 0 ? 0 : be32(data, 8 + 4 * (b - 1));
        size_t hi = be32(data, 8 + 4 * b);
        while (lo < hi)
        {
            immutable mid = lo + (hi - lo) / 2;
            if (idAt(mid) < id)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo;
    }

    /// Find `id`; on success store its pack offset in `offset`.
    bool find(const ObjectId id, out ulong offset) const @safe pure
    {
        immutable i = lowerBound(id);
        if (i < count_ && idAt(i) == id)
        {
            offset = offsetAt(i);
            return true;
        }
        return false;
    }

    /// True if the index lists `id`.
    bool contains(const ObjectId id) const @safe pure nothrow @nogc
    {
        immutable i = lowerBound(id);
        return i < count_ && idAt(i) == id;
    }
}

private uint be32(scope const(ubyte)[] d, size_t p) @safe pure nothrow @nogc
{
    return (cast(uint) d[p] << 24) | (cast(uint) d[p + 1] << 16) | (cast(uint) d[p + 2] << 8) | d[p + 3];
}

unittest
{
    import std.exception : assertThrown;

    // Build a tiny index with three ids: 00.., 00.. (larger), ff...
    ubyte[] buf;
    buf ~= [0xff, 't', 'O', 'c', 0, 0, 0, 2];
    ObjectId a, b, c;
    a.bytes[19] = 1;
    b.bytes[19] = 2;
    c.bytes[] = 0xff;
    foreach (i; 0 .. 256)
    {
        immutable n = i < 255 ? 2 : 3;
        buf ~= [0, 0, 0, cast(ubyte) n];
    }
    foreach (id; [a, b, c])
        buf ~= id.bytes[];
    buf ~= new ubyte[](12); // CRCs
    buf ~= [0, 0, 0, 12, 0, 0, 0, 40, 0x80, 0, 0, 0]; // offsets (last one is big)
    buf ~= [0, 0, 0, 1, 0, 0, 0, 7]; // one 64-bit offset: 0x1_0000_0007
    buf ~= new ubyte[](40);
    auto ix = PackIndex.parse(buf);
    assert(ix.length == 3);
    ulong off;
    assert(ix.find(b, off) && off == 40);
    assert(ix.find(c, off) && off == 0x1_0000_0007);
    assert(!ix.find(ObjectId.parse("0000000000000000000000000000000000000003"), off));
    assert(ix.lowerBound(ObjectId.parse("8000000000000000000000000000000000000000")) == 2);
    assertThrown!GitError(PackIndex.parse(buf[0 .. 100]));
}
