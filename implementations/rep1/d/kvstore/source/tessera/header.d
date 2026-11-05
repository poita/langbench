/// The header page (page 1) and the secondary-index directory.
module tessera.header;

import tessera.bytes;
import tessera.constants;

/// One slot of the index directory.
struct IndexSlot
{
    /// The slot holds a live index.
    bool live;
    /// Path text, segments joined by `.`.
    string path;
    /// Path split into segments (derived from `path`).
    string[] segments;
    /// Root page of the index tree, 0 when empty.
    uint root;
    /// Number of entries in the index.
    uint entries;
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
    IndexSlot[maxIndexes] slots;
}

private static immutable ubyte[8] magic = ['T', 'E', 'S', 'S', 'E', 'R', 'A', '1'];

/// Split a path text at `.`.
string[] splitPath(string text) pure nothrow @safe
{
    string[] r;
    size_t s = 0;
    foreach (i, c; text)
        if (c == '.')
        {
            r ~= text[s .. i];
            s = i + 1;
        }
    r ~= text[s .. $];
    return r;
}

/// Encode a header into its canonical 1024-byte page.
ubyte[] encodeHeader(const ref Header h) pure nothrow @safe
{
    auto p = new ubyte[pageSize];
    p[0 .. 8] = magic[];
    setU16(p, 8, 1);
    setU16(p, 10, cast(uint) pageSize);
    setU32(p, 12, h.pageCount);
    setU32(p, 16, h.freelistHead);
    setU32(p, 20, h.freelistCount);
    setU32(p, 24, h.primaryRoot);
    setU32(p, 28, h.primaryCount);
    setU64(p, 32, h.commitCounter);
    setU32(p, 40, h.indexCount);
    foreach (s, ref slot; h.slots)
    {
        if (!slot.live)
            continue;
        immutable o = 128 + 48 * s;
        p[o] = 1;
        p[o + 1] = cast(ubyte) slot.path.length;
        p[o + 2 .. o + 2 + slot.path.length] = asBytes(slot.path)[];
        setU32(p, o + 32, slot.root);
        setU32(p, o + 36, slot.entries);
    }
    return p;
}

/// Decode a header page.
Header decodeHeader(const(ubyte)[] p) pure nothrow @safe
{
    Header h;
    h.pageCount = getU32(p, 12);
    h.freelistHead = getU32(p, 16);
    h.freelistCount = getU32(p, 20);
    h.primaryRoot = getU32(p, 24);
    h.primaryCount = getU32(p, 28);
    h.commitCounter = getU64(p, 32);
    h.indexCount = getU32(p, 40);
    foreach (s, ref slot; h.slots)
    {
        immutable o = 128 + 48 * s;
        if (p[o] != 1)
            continue;
        slot.live = true;
        slot.path = toStr(p[o + 2 .. o + 2 + p[o + 1]]);
        slot.segments = splitPath(slot.path);
        slot.root = getU32(p, o + 32);
        slot.entries = getU32(p, o + 36);
    }
    return h;
}
