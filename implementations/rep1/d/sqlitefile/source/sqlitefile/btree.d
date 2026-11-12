/// B-tree page and cell decoding, overflow chains, and the tree walks the
/// query engine needs: full table scan, row count, rowid seek, and an
/// equality search of an index.
module sqlitefile.btree;

import sqlitefile.bytes;
import sqlitefile.database;
import sqlitefile.errors;

@safe:

/// The four B-tree page types.
enum PageType : ubyte
{
    interiorIndex = 0x02,
    interiorTable = 0x05,
    leafIndex = 0x0a,
    leafTable = 0x0d,
}

private enum maxDepth = 64; // guards against cycles in a corrupt file

/// A decoded page header plus access to its cell pointer array.
struct Page
{
    const(ubyte)[] data; /// the page's bytes
    PageType type;
    size_t cellCount;
    uint rightChild; /// interior pages only
    private size_t arrayStart;

    /// True for leaf pages.
    bool isLeaf() const pure nothrow @nogc
    {
        return type == PageType.leafIndex || type == PageType.leafTable;
    }

    /// Offset (from the page start) of the content of cell `i`.
    size_t cellOffset(size_t i) const pure
    {
        if (i >= cellCount)
            throw new FormatException("cell index out of range");
        return readU16(data, arrayStart + 2 * i);
    }
}

/// Reads the header of page `number`.
Page openPage(const Database db, uint number) pure
{
    Page p;
    p.data = db.page(number);
    const base = number == 1 ? 100 : 0;
    checkRange(p.data, base, 8);
    const t = p.data[base];
    switch (t)
    {
    case PageType.interiorIndex:
    case PageType.interiorTable:
        p.type = cast(PageType) t;
        p.rightChild = readU32(p.data, base + 8);
        p.arrayStart = base + 12;
        break;
    case PageType.leafIndex:
    case PageType.leafTable:
        p.type = cast(PageType) t;
        p.arrayStart = base + 8;
        break;
    default:
        throw new FormatException("unexpected B-tree page type");
    }
    p.cellCount = readU16(p.data, base + 3);
    checkRange(p.data, p.arrayStart, 2 * p.cellCount);
    return p;
}

/// How many bytes of a payload of `total` bytes are stored on the B-tree
/// page itself (SPEC §1.5); `usable` is the usable page size `U`.
size_t localPayloadSize(size_t usable, ulong total, bool tableLeaf) pure nothrow @nogc
{
    const m = ((usable - 12) * 32 / 255) - 23;
    const x = tableLeaf ? usable - 35 : ((usable - 12) * 64 / 255) - 23;
    if (total <= x)
        return cast(size_t) total;
    const k = m + cast(size_t)((total - m) % (usable - 4));
    return k <= x ? k : m;
}

/// Returns the complete payload of the cell whose payload bytes begin at
/// `pos` on `page`, following the overflow chain when necessary.
const(ubyte)[] readPayload(const Database db, const(ubyte)[] page, size_t pos,
        ulong total, bool tableLeaf)
{
    const usable = db.usableSize;
    const local = localPayloadSize(usable, total, tableLeaf);
    checkRange(page, pos, local);
    if (local == total)
        return page[pos .. pos + local];
    if (total > cast(ulong) db.pageCount * db.pageSize)
        throw new FormatException("payload larger than the database");

    auto buf = new ubyte[cast(size_t) total];
    buf[0 .. local] = page[pos .. pos + local];
    size_t filled = local;
    uint next = readU32(page, pos + local);
    uint hops = 0;
    while (filled < total)
    {
        if (next == 0 || hops++ > db.pageCount)
            throw new FormatException("broken overflow chain");
        const op = db.page(next);
        next = readU32(op, 0);
        size_t take = usable - 4;
        if (take > total - filled)
            take = cast(size_t)(total - filled);
        checkRange(op, 4, take);
        buf[filled .. filled + take] = op[4 .. 4 + take];
        filled += take;
    }
    return buf;
}

// --- cell accessors ---------------------------------------------------------

/// Rowid and payload of table-leaf cell `i`.
void tableLeafCell(const Database db, in Page pg, size_t i, out long rowid,
        out const(ubyte)[] payload)
{
    assert(pg.type == PageType.leafTable);
    auto pos = pg.cellOffset(i);
    long total;
    pos += readVarint(pg.data, pos, total);
    pos += readVarint(pg.data, pos, rowid);
    if (total < 0)
        throw new FormatException("negative payload size");
    payload = readPayload(db, pg.data, pos, total, true);
}

private long tableLeafRowid(in Page pg, size_t i)
{
    auto pos = pg.cellOffset(i);
    long total, rowid;
    pos += readVarint(pg.data, pos, total);
    readVarint(pg.data, pos, rowid);
    return rowid;
}

private uint tableInteriorChild(in Page pg, size_t i)
{
    return readU32(pg.data, pg.cellOffset(i));
}

private long tableInteriorKey(in Page pg, size_t i)
{
    long key;
    readVarint(pg.data, pg.cellOffset(i) + 4, key);
    return key;
}

/// Left child page and full payload of index cell `i` (interior or leaf).
private const(ubyte)[] indexCell(const Database db, in Page pg, size_t i, out uint leftChild)
{
    auto pos = pg.cellOffset(i);
    leftChild = 0;
    if (!pg.isLeaf)
    {
        leftChild = readU32(pg.data, pos);
        pos += 4;
    }
    long total;
    pos += readVarint(pg.data, pos, total);
    if (total < 0)
        throw new FormatException("negative payload size");
    return readPayload(db, pg.data, pos, total, false);
}

// --- table B-trees ----------------------------------------------------------

/// Visits every row of the table B-tree rooted at `root` in ascending rowid
/// order. The visitor returns `false` to stop early; `walkTable` then also
/// returns `false`.
bool walkTable(const Database db, uint root,
        scope bool delegate(long rowid, const(ubyte)[] payload) @safe visit, int depth = 0)
{
    if (depth > maxDepth)
        throw new FormatException("B-tree too deep (cycle?)");
    const pg = openPage(db, root);
    if (pg.type == PageType.leafTable)
    {
        foreach (i; 0 .. pg.cellCount)
        {
            long rowid;
            const(ubyte)[] payload;
            tableLeafCell(db, pg, i, rowid, payload);
            if (!visit(rowid, payload))
                return false;
        }
        return true;
    }
    if (pg.type != PageType.interiorTable)
        throw new FormatException("index page in a table B-tree");
    foreach (i; 0 .. pg.cellCount)
        if (!walkTable(db, tableInteriorChild(pg, i), visit, depth + 1))
            return false;
    return walkTable(db, pg.rightChild, visit, depth + 1);
}

/// Counts the rows of a table B-tree by summing its leaf pages' cell counts.
ulong countTable(const Database db, uint root, int depth = 0)
{
    if (depth > maxDepth)
        throw new FormatException("B-tree too deep (cycle?)");
    const pg = openPage(db, root);
    if (pg.type == PageType.leafTable)
        return pg.cellCount;
    if (pg.type != PageType.interiorTable)
        throw new FormatException("index page in a table B-tree");
    ulong n = 0;
    foreach (i; 0 .. pg.cellCount)
        n += countTable(db, tableInteriorChild(pg, i), depth + 1);
    return n + countTable(db, pg.rightChild, depth + 1);
}

/// Finds the row with the given rowid by descending the table B-tree.
bool findTableRow(const Database db, uint root, long rowid, out const(ubyte)[] payload)
{
    uint pageNo = root;
    foreach (_; 0 .. maxDepth + 1)
    {
        const pg = openPage(db, pageNo);
        if (pg.type == PageType.leafTable)
        {
            size_t lo = 0, hi = pg.cellCount;
            while (lo < hi)
            {
                const mid = lo + (hi - lo) / 2;
                if (tableLeafRowid(pg, mid) < rowid)
                    lo = mid + 1;
                else
                    hi = mid;
            }
            if (lo == pg.cellCount || tableLeafRowid(pg, lo) != rowid)
                return false;
            long r;
            tableLeafCell(db, pg, lo, r, payload);
            return true;
        }
        if (pg.type != PageType.interiorTable)
            throw new FormatException("index page in a table B-tree");
        // first key >= rowid; its left child holds every rowid <= key
        size_t lo = 0, hi = pg.cellCount;
        while (lo < hi)
        {
            const mid = lo + (hi - lo) / 2;
            if (tableInteriorKey(pg, mid) < rowid)
                lo = mid + 1;
            else
                hi = mid;
        }
        pageNo = lo == pg.cellCount ? pg.rightChild : tableInteriorChild(pg, lo);
    }
    throw new FormatException("B-tree too deep (cycle?)");
}

// --- index B-trees ----------------------------------------------------------

/// Visits, in key order, every entry of the index B-tree rooted at `root`
/// whose key compares equal to the search key.
///
/// `compareToKey` receives an entry's payload and returns <0, 0 or >0
/// according to whether the entry sorts before, equal to or after the key
/// (comparing only as many columns as the key has). Entries must be ordered
/// consistently with it. The visitor returns `false` to stop early.
bool searchIndex(const Database db, uint root,
        scope int delegate(const(ubyte)[] payload) @safe compareToKey,
        scope bool delegate(const(ubyte)[] payload) @safe visit, int depth = 0)
{
    if (depth > maxDepth)
        throw new FormatException("B-tree too deep (cycle?)");
    const pg = openPage(db, root);
    if (pg.type != PageType.leafIndex && pg.type != PageType.interiorIndex)
        throw new FormatException("table page in an index B-tree");

    // lo = first cell whose entry is >= key
    size_t lo = 0, hi = pg.cellCount;
    uint dummy;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        if (compareToKey(indexCell(db, pg, mid, dummy)) < 0)
            lo = mid + 1;
        else
            hi = mid;
    }

    foreach (i; lo .. pg.cellCount)
    {
        uint left;
        const payload = indexCell(db, pg, i, left);
        if (!pg.isLeaf && !searchIndex(db, left, compareToKey, visit, depth + 1))
            return false;
        const c = compareToKey(payload);
        if (c > 0)
            return true;
        if (!visit(payload))
            return false;
    }
    if (!pg.isLeaf)
        return searchIndex(db, pg.rightChild, compareToKey, visit, depth + 1);
    return true;
}

unittest
{
    // U = 4096: M = 489, table-leaf X = 4061, index X = 1002.
    assert(localPayloadSize(4096, 100, true) == 100);
    assert(localPayloadSize(4096, 4061, true) == 4061); // exactly X
    assert(localPayloadSize(4096, 4062, true) == 489); // one past X
    assert(localPayloadSize(4096, 1002, false) == 1002);
    assert(localPayloadSize(4096, 1003, false) == 489);
    // P - M wraps modulo U - 4: K = 489 + 10 <= X
    assert(localPayloadSize(4096, 489 + 4092 + 10, true) == 499);
    // U = 512: M = 39, table X = 477
    assert(localPayloadSize(512, 477, true) == 477);
    assert(localPayloadSize(512, 478, true) == 39);
}
