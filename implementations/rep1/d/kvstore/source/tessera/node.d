/// Canonical B+tree pages: decoding and encoding (SPEC §11).
module tessera.node;

import tessera.bytes;
import tessera.constants;

/// Page type bytes (SPEC §7.1).
enum PageType : ubyte
{
    free = 0,
    primaryLeaf = 1,
    interior = 2,
    overflow = 3,
    indexLeaf = 5,
}

/// One cell of a B+tree page. Which fields are meaningful depends on the page
/// type: a primary leaf cell uses `key`, `docLen`, `overflow` and `inline`; an
/// interior cell uses `key` and `child`; an index leaf cell only `key`.
struct Cell
{
    /// The key bytes (primary key, separator, or index key).
    const(ubyte)[] key;
    /// Interior: child page number.
    uint child;
    /// Primary leaf: total serialised document length.
    uint docLen;
    /// Primary leaf: first overflow page, 0 for none.
    uint overflow;
    /// Primary leaf: the document bytes stored in the cell.
    const(ubyte)[] inline;
}

/// The logical content of a B+tree page: ordered cells plus the header link.
struct Node
{
    /// `primaryLeaf`, `interior` or `indexLeaf`.
    PageType type;
    /// Interior: the rightmost child. Leaf: the next leaf, 0 for the last.
    uint link;
    /// Cells in ascending key order.
    Cell[] cells;

    /// Whether this is a leaf page.
    bool isLeaf() const @safe pure nothrow @nogc
    {
        return type != PageType.interior;
    }

    /// Encoded size of a cell on this kind of page.
    size_t cellSize(ref const Cell c) const @safe pure nothrow @nogc
    {
        final switch (type)
        {
        case PageType.primaryLeaf:
            return 12 + c.key.length + c.inline.length;
        case PageType.interior:
            return 6 + c.key.length;
        case PageType.indexLeaf:
            return 2 + c.key.length;
        case PageType.free, PageType.overflow:
            assert(0);
        }
    }

    /// Cost of a cell: its size plus its 2-byte pointer.
    size_t cellCost(ref const Cell c) const @safe pure nothrow @nogc
    {
        return cellSize(c) + 2;
    }

    /// Payload size of the page (SPEC §11.2).
    size_t used() const @safe pure nothrow @nogc
    {
        size_t u = 0;
        foreach (ref c; cells)
            u += cellCost(c);
        return u;
    }
}

/// Decode a B+tree page.
Node decodeNode(const(ubyte)[] page) @safe pure nothrow
{
    Node n;
    n.type = cast(PageType) page[0];
    immutable count = getU16(page, 2);
    n.link = getU32(page, 8);
    n.cells = new Cell[count];
    foreach (i; 0 .. count)
    {
        immutable off = getU16(page, BTREE_HEADER + 2 * i);
        Cell c;
        final switch (n.type)
        {
        case PageType.primaryLeaf:
            immutable klen = getU16(page, off);
            c.docLen = getU32(page, off + 2);
            immutable ilen = getU16(page, off + 6);
            c.overflow = getU32(page, off + 8);
            c.key = page[off + 12 .. off + 12 + klen];
            c.inline = page[off + 12 + klen .. off + 12 + klen + ilen];
            break;
        case PageType.interior:
            immutable klen = getU16(page, off);
            c.child = getU32(page, off + 2);
            c.key = page[off + 6 .. off + 6 + klen];
            break;
        case PageType.indexLeaf:
            immutable klen = getU16(page, off);
            c.key = page[off + 2 .. off + 2 + klen];
            break;
        case PageType.free, PageType.overflow:
            assert(0, "not a B+tree page");
        }
        n.cells[i] = c;
    }
    return n;
}

/// Encode a node to its canonical page (SPEC §11.2). The payload must fit.
ubyte[] encodeNode(ref const Node n) @safe pure nothrow
in (n.used() <= CAPACITY)
{
    auto p = new ubyte[PAGE_SIZE];
    immutable count = n.cells.length;
    p[0] = n.type;
    putU16(p, 2, cast(uint) count);
    putU32(p, 8, n.link);
    size_t total = 0;
    foreach (ref c; n.cells)
        total += n.cellSize(c);
    immutable start = PAGE_SIZE - total;
    putU16(p, 4, cast(uint) start);
    size_t off = start;
    foreach (i, ref c; n.cells)
    {
        putU16(p, BTREE_HEADER + 2 * i, cast(uint) off);
        final switch (n.type)
        {
        case PageType.primaryLeaf:
            putU16(p, off, cast(uint) c.key.length);
            putU32(p, off + 2, c.docLen);
            putU16(p, off + 6, cast(uint) c.inline.length);
            putU32(p, off + 8, c.overflow);
            p[off + 12 .. off + 12 + c.key.length] = c.key[];
            p[off + 12 + c.key.length .. off + 12 + c.key.length + c.inline.length] = c.inline[];
            break;
        case PageType.interior:
            putU16(p, off, cast(uint) c.key.length);
            putU32(p, off + 2, c.child);
            p[off + 6 .. off + 6 + c.key.length] = c.key[];
            break;
        case PageType.indexLeaf:
            putU16(p, off, cast(uint) c.key.length);
            p[off + 2 .. off + 2 + c.key.length] = c.key[];
            break;
        case PageType.free, PageType.overflow:
            assert(0);
        }
        off += n.cellSize(c);
    }
    return p;
}

@safe pure nothrow unittest
{
    // SPEC §11.3: a leaf with one cell, key "a", document 1
    Node n;
    n.type = PageType.primaryLeaf;
    Cell c;
    c.key = [0x61];
    c.docLen = 9;
    c.inline = [3, 0, 0, 0, 0, 0, 0, 0, 1];
    n.cells = [c];
    auto p = encodeNode(n);
    assert(p[0 .. 8] == [1, 0, 0, 1, 3, 0xea, 0, 0]);
    assert(p[16 .. 18] == [3, 0xea]);
    assert(p[1002 .. 1024] == [0, 1, 0, 0, 0, 9, 0, 9, 0, 0, 0, 0, 0x61, 3, 0, 0, 0, 0, 0, 0, 0, 1]);
    assert(n.used() == 24);
    auto back = decodeNode(p);
    assert(encodeNode(back) == p);
}

@safe pure nothrow unittest
{
    // SPEC §11.4: an interior page with one separator "m" over child 2, link 3
    Node n;
    n.type = PageType.interior;
    n.link = 3;
    Cell c;
    c.key = [0x6d];
    c.child = 2;
    n.cells = [c];
    auto p = encodeNode(n);
    assert(p[0 .. 12] == [2, 0, 0, 1, 3, 0xf9, 0, 0, 0, 0, 0, 3]);
    assert(p[1018 .. 1024] == [1, 0, 0, 0, 2, 0x6d]);
    // an empty page
    Node e;
    e.type = PageType.indexLeaf;
    auto ep = encodeNode(e);
    assert(ep[4 .. 6] == [4, 0]);
}
