/// B-tree traversal: table scans, rowid seeks, row counting and index lookups.
module sqlitefile.btree;

import sqlitefile.bytes;
import sqlitefile.database;
import sqlitefile.errors;
import sqlitefile.record;
import sqlitefile.value;

@safe:

private enum ubyte interiorIndex = 0x02, interiorTable = 0x05, leafIndex = 0x0a, leafTable = 0x0d;
private enum maxDepth = 64;

/// A B-tree page header plus the page bytes (a view, nothing is copied).
struct BTreePage
{
    const(ubyte)[] bytes;
    size_t header; /// 100 on page 1, otherwise 0
    ubyte type;
    uint cellCount;
    uint rightChild; /// interior pages only

    bool isLeaf() const pure nothrow @nogc
    {
        return type == leafIndex || type == leafTable;
    }

    bool isTable() const pure nothrow @nogc
    {
        return type == leafTable || type == interiorTable;
    }

    /// Offset of cell `i` within the page.
    size_t cellOffset(uint i) const pure
    {
        immutable arr = header + (isLeaf ? 8 : 12);
        immutable off = readBE16(bytes, arr + 2 * cast(size_t) i);
        if (off >= bytes.length)
            throw new FormatException("cell offset out of range");
        return off;
    }

    /// Left child of interior cell `i`.
    uint leftChild(uint i) const pure
    {
        return readBE32(bytes, cellOffset(i));
    }
}

/// Loads the header of page `no`.
BTreePage loadPage(const Database db, uint no) pure
{
    BTreePage p;
    p.bytes = db.page(no);
    p.header = no == 1 ? 100 : 0;
    p.type = p.bytes[p.header];
    if (p.type != interiorIndex && p.type != interiorTable
        && p.type != leafIndex && p.type != leafTable)
        throw new FormatException("not a B-tree page");
    p.cellCount = readBE16(p.bytes, p.header + 3);
    if (!p.isLeaf)
        p.rightChild = readBE32(p.bytes, p.header + 8);
    immutable arrEnd = p.header + (p.isLeaf ? 8 : 12) + 2 * cast(size_t) p.cellCount;
    if (arrEnd > p.bytes.length)
        throw new FormatException("cell pointer array overruns the page");
    return p;
}

/// Location of a cell's payload.
struct CellInfo
{
    ulong total; /// full payload size P
    size_t start; /// offset of the payload within the page
    size_t local; /// bytes stored on the page
    long rowid; /// table leaf cells only
}

/// Decodes the cell header of cell `i` and computes how much payload is local (SPEC §1.5).
CellInfo parseCell(const Database db, in BTreePage pg, uint i) pure
{
    CellInfo ci;
    size_t pos = pg.cellOffset(i);
    final switch (pg.type)
    {
    case leafTable:
        ci.total = cast(ulong) readVarint(pg.bytes, pos);
        ci.rowid = readVarint(pg.bytes, pos);
        break;
    case leafIndex:
        ci.total = cast(ulong) readVarint(pg.bytes, pos);
        break;
    case interiorIndex:
        pos += 4;
        ci.total = cast(ulong) readVarint(pg.bytes, pos);
        break;
    case interiorTable:
        throw new FormatException("interior table cells have no payload");
    }
    ci.start = pos;
    immutable x = pg.type == leafTable ? db.maxLocalTable : db.maxLocalIndex;
    if (ci.total <= x)
        ci.local = cast(size_t) ci.total;
    else
    {
        immutable m = db.minLocal;
        immutable k = m + cast(size_t)((ci.total - m) % (db.usable - 4));
        ci.local = k <= x ? k : m;
    }
    if (ci.start + ci.local > pg.bytes.length)
        throw new FormatException("cell payload overruns the page");
    return ci;
}

/// The full payload of a cell.
///
/// When the payload is entirely local this is a view into the page; otherwise
/// the overflow chain is gathered into `db.scratch`, and `stable` is false
/// because the next overflowing cell overwrites it.
const(ubyte)[] cellPayload(Database db, in BTreePage pg, in CellInfo ci, out bool stable)
{
    if (ci.local == ci.total)
    {
        stable = true;
        return pg.bytes[ci.start .. ci.start + cast(size_t) ci.total];
    }
    stable = false;
    immutable total = cast(size_t) ci.total;
    if (db.scratch.length < total)
        db.scratch.length = total;
    auto buf = db.scratch;
    buf[0 .. ci.local] = pg.bytes[ci.start .. ci.start + ci.local];
    size_t got = ci.local;
    if (ci.start + ci.local + 4 > pg.bytes.length)
        throw new FormatException("missing overflow pointer");
    uint next = readBE32(pg.bytes, ci.start + ci.local);
    immutable chunk = db.usable - 4;
    while (got < total)
    {
        if (next == 0)
            throw new FormatException("overflow chain ends early");
        const op = db.page(next);
        immutable take = total - got < chunk ? total - got : chunk;
        buf[got .. got + take] = op[4 .. 4 + take];
        got += take;
        next = readBE32(op, 0);
    }
    return buf[0 .. total];
}

/// Callback for table scans. Return false to stop the walk.
alias RowVisitor = bool delegate(long rowid, const(ubyte)[] payload, bool stable) @safe;

/// Visits every row of the table B-tree rooted at `root` in ascending rowid
/// order. Returns false if the visitor stopped the walk.
bool walkTable(Database db, uint root, scope RowVisitor visit, uint depth = 0)
{
    if (depth > maxDepth)
        throw new FormatException("B-tree too deep (cycle?)");
    const pg = loadPage(db, root);
    if (pg.type == leafTable)
    {
        foreach (i; 0 .. pg.cellCount)
        {
            immutable ci = parseCell(db, pg, i);
            bool stable;
            const payload = cellPayload(db, pg, ci, stable);
            if (!visit(ci.rowid, payload, stable))
                return false;
        }
        return true;
    }
    if (pg.type != interiorTable)
        throw new FormatException("expected a table B-tree page");
    foreach (i; 0 .. pg.cellCount)
        if (!walkTable(db, pg.leftChild(i), visit, depth + 1))
            return false;
    return walkTable(db, pg.rightChild, visit, depth + 1);
}

/// Number of rows in the table rooted at `root`; reads only page headers.
ulong countRows(Database db, uint root, uint depth = 0)
{
    if (depth > maxDepth)
        throw new FormatException("B-tree too deep (cycle?)");
    const pg = loadPage(db, root);
    if (pg.type == leafTable)
        return pg.cellCount;
    if (pg.type != interiorTable)
        throw new FormatException("expected a table B-tree page");
    ulong n = 0;
    foreach (i; 0 .. pg.cellCount)
        n += countRows(db, pg.leftChild(i), depth + 1);
    return n + countRows(db, pg.rightChild, depth + 1);
}

/// Finds the row with the given rowid by descending the table B-tree with
/// binary searches. Returns false if there is no such row.
bool seekTable(Database db, uint root, long rowid, scope RowVisitor visit)
{
    uint pgno = root;
    foreach (_; 0 .. maxDepth)
    {
        const pg = loadPage(db, pgno);
        if (pg.type == interiorTable)
        {
            // first cell whose key >= rowid
            uint lo = 0, hi = pg.cellCount;
            while (lo < hi)
            {
                immutable mid = (lo + hi) / 2;
                size_t pos = pg.cellOffset(mid) + 4;
                if (readVarint(pg.bytes, pos) < rowid)
                    lo = mid + 1;
                else
                    hi = mid;
            }
            pgno = lo < pg.cellCount ? pg.leftChild(lo) : pg.rightChild;
        }
        else if (pg.type == leafTable)
        {
            uint lo = 0, hi = pg.cellCount;
            while (lo < hi)
            {
                immutable mid = (lo + hi) / 2;
                size_t pos = pg.cellOffset(mid);
                readVarint(pg.bytes, pos);
                if (readVarint(pg.bytes, pos) < rowid)
                    lo = mid + 1;
                else
                    hi = mid;
            }
            if (lo >= pg.cellCount)
                return false;
            immutable ci = parseCell(db, pg, lo);
            if (ci.rowid != rowid)
                return false;
            bool stable;
            const payload = cellPayload(db, pg, ci, stable);
            visit(ci.rowid, payload, stable);
            return true;
        }
        else
            throw new FormatException("expected a table B-tree page");
    }
    throw new FormatException("B-tree too deep (cycle?)");
}

/// Key-directed search of an index B-tree.
private struct IndexSearch
{
    Database db;
    Value key;
    long[] rowids;
    RecordReader rr;

    /// Compares the first column of entry `i` of `pg` with the key.
    int compareEntry(in BTreePage pg, uint i)
    {
        immutable ci = parseCell(db, pg, i);
        bool stable;
        rr.parse(cellPayload(db, pg, ci, stable));
        return compareValues(rr.value(0), key);
    }

    void collect()
    {
        const last = rr.value(rr.length - 1);
        if (last.kind != ValueKind.integer)
            throw new FormatException("index entry does not end in a rowid");
        rowids ~= last.i;
    }

    /// Returns false once an entry greater than the key has been seen.
    bool walk(uint pgno, uint depth)
    {
        if (depth > maxDepth)
            throw new FormatException("B-tree too deep (cycle?)");
        const pg = loadPage(db, pgno);
        if (pg.type != leafIndex && pg.type != interiorIndex)
            throw new FormatException("expected an index B-tree page");
        uint lo = 0, hi = pg.cellCount;
        while (lo < hi)
        {
            immutable mid = (lo + hi) / 2;
            if (compareEntry(pg, mid) < 0)
                lo = mid + 1;
            else
                hi = mid;
        }
        foreach (j; lo .. pg.cellCount)
        {
            if (!pg.isLeaf && !walk(pg.leftChild(j), depth + 1))
                return false;
            immutable c = compareEntry(pg, j);
            if (c > 0)
                return false;
            collect();
        }
        if (!pg.isLeaf)
            return walk(pg.rightChild, depth + 1);
        return true;
    }
}

/// Collects the rowids of every entry of the index rooted at `root` whose
/// first column equals `key`, in index order.
long[] indexFind(Database db, uint root, in Value key)
{
    IndexSearch s;
    s.db = db;
    s.key = key;
    s.walk(root, 0);
    return s.rowids;
}
