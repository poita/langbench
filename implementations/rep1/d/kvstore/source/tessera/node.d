/// Canonical B+tree pages: decoding into cells, canonical re-encoding, and
/// raw (zero-copy) access to a stored page image.
module tessera.node;

import tessera.bytes;
import tessera.constants;

/// The three kinds of tree page; the value is the page's type byte.
enum NodeKind : ubyte
{
    primaryLeaf = typePrimaryLeaf,
    interior = typeInterior,
    indexLeaf = typeIndexLeaf,
}

/// One cell of any kind of page.
///
/// Interior cells use `key` and `child`; index-leaf cells use `key`;
/// primary-leaf cells use `key`, `docLen`, `overflow` and `data` (the inline
/// document bytes).
struct Cell
{
    const(ubyte)[] key;
    uint child;
    uint docLen;
    uint overflow;
    const(ubyte)[] data;
}

/// A decoded page: its cells in key order and its `link` field.
struct Node
{
    NodeKind kind;
    uint link;
    Cell[] cells;
}

/// Encoded size of a cell, excluding its 2-byte pointer.
size_t cellSize(NodeKind kind, const ref Cell c) pure nothrow @nogc @safe
{
    final switch (kind)
    {
    case NodeKind.primaryLeaf: return 12 + c.key.length + c.data.length;
    case NodeKind.interior: return 6 + c.key.length;
    case NodeKind.indexLeaf: return 2 + c.key.length;
    }
}

/// Payload size: pointers plus cells.
size_t usedBytes(const ref Node n) pure nothrow @nogc @safe
{
    size_t u = 0;
    foreach (ref c; n.cells)
        u += 2 + cellSize(n.kind, c);
    return u;
}

/// Encode a node into its canonical 1024-byte page.
ubyte[] encodeNode(const Node n) pure nothrow @safe
{
    auto p = new ubyte[pageSize];
    immutable used = usedBytes(n);
    assert(used <= pageCapacity);
    immutable cellsBytes = used - 2 * n.cells.length;
    immutable start = pageSize - cellsBytes;
    p[0] = n.kind;
    setU16(p, 2, cast(uint) n.cells.length);
    setU16(p, 4, cast(uint) start);
    setU32(p, 8, n.link);
    size_t off = start;
    foreach (i, ref c; n.cells)
    {
        setU16(p, nodeHeader + 2 * i, cast(uint) off);
        setU16(p, off, cast(uint) c.key.length);
        final switch (n.kind)
        {
        case NodeKind.primaryLeaf:
            setU32(p, off + 2, c.docLen);
            setU16(p, off + 6, cast(uint) c.data.length);
            setU32(p, off + 8, c.overflow);
            p[off + 12 .. off + 12 + c.key.length] = c.key[];
            p[off + 12 + c.key.length .. off + 12 + c.key.length + c.data.length] = c.data[];
            break;
        case NodeKind.interior:
            setU32(p, off + 2, c.child);
            p[off + 6 .. off + 6 + c.key.length] = c.key[];
            break;
        case NodeKind.indexLeaf:
            p[off + 2 .. off + 2 + c.key.length] = c.key[];
            break;
        }
        off += cellSize(n.kind, c);
    }
    return p;
}

/// Decode a stored page. Keys and data are views into `page`.
Node decodeNode(const(ubyte)[] page) pure nothrow @safe
{
    Node n;
    n.kind = cast(NodeKind) page[0];
    n.link = getU32(page, 8);
    immutable cnt = getU16(page, 2);
    n.cells = new Cell[cnt];
    foreach (i, ref c; n.cells)
    {
        immutable off = rawCellOffset(page, i);
        immutable kl = getU16(page, off);
        final switch (n.kind)
        {
        case NodeKind.primaryLeaf:
            c.docLen = getU32(page, off + 2);
            immutable il = getU16(page, off + 6);
            c.overflow = getU32(page, off + 8);
            c.key = page[off + 12 .. off + 12 + kl];
            c.data = page[off + 12 + kl .. off + 12 + kl + il];
            break;
        case NodeKind.interior:
            c.child = getU32(page, off + 2);
            c.key = page[off + 6 .. off + 6 + kl];
            break;
        case NodeKind.indexLeaf:
            c.key = page[off + 2 .. off + 2 + kl];
            break;
        }
    }
    return n;
}

// ------------------------------------------------------------- raw access

/// Number of cells on a stored B+tree page.
size_t rawCount(const(ubyte)[] page) pure nothrow @nogc @safe
{
    return getU16(page, 2);
}

/// The `link` field of a stored B+tree page.
uint rawLink(const(ubyte)[] page) pure nothrow @nogc @safe
{
    return getU32(page, 8);
}

/// Byte offset of cell `i`.
size_t rawCellOffset(const(ubyte)[] page, size_t i) pure nothrow @nogc @safe
{
    return getU16(page, nodeHeader + 2 * i);
}

/// The key of cell `i`, as a view into the page.
const(ubyte)[] rawKey(const(ubyte)[] page, size_t i) pure nothrow @nogc @safe
{
    immutable off = rawCellOffset(page, i);
    immutable kl = getU16(page, off);
    switch (page[0])
    {
    case typePrimaryLeaf: return page[off + 12 .. off + 12 + kl];
    case typeInterior: return page[off + 6 .. off + 6 + kl];
    default: return page[off + 2 .. off + 2 + kl];
    }
}

/// The child pointer of interior cell `i`.
uint rawChild(const(ubyte)[] page, size_t i) pure nothrow @nogc @safe
{
    return getU32(page, rawCellOffset(page, i) + 2);
}

/// Smallest cell index whose key is `>= key` (the cell count when none is).
/// On an interior page this is the child to descend into.
size_t rawLowerBound(const(ubyte)[] page, const(ubyte)[] key) pure nothrow @nogc @safe
{
    size_t lo = 0, hi = rawCount(page);
    while (lo < hi)
    {
        immutable mid = (lo + hi) / 2;
        if (compareBytes(key, rawKey(page, mid)) <= 0)
            hi = mid;
        else
            lo = mid + 1;
    }
    return lo;
}
