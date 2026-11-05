/// Secondary indexes: key encoding, maintenance on writes, build and drop,
/// and candidate range scans.
module tessera.indexing;

import std.algorithm.sorting : sort;

import tessera.ast : joinPath;
import tessera.btree;
import tessera.bytes;
import tessera.constants;
import tessera.docstore;
import tessera.errors;
import tessera.header;
import tessera.lexer : CmpOp;
import tessera.node;
import tessera.pager;
import tessera.value;

/// Index entry keys of one document, one per slot (null where the document is
/// not indexed or the slot is not live).
alias IndexKeys = ubyte[][maxIndexes];

/// Append the order-preserving encoding of a scalar value. Returns false for
/// lists and objects, which have none.
bool appendVkey(ref ByteBuffer o, Value v) pure nothrow @safe
{
    final switch (v.kind)
    {
    case Kind.null_:
        o.put(0x10);
        return true;
    case Kind.boolean:
        o.put(v.num ? 0x21 : 0x20);
        return true;
    case Kind.integer:
        o.put(0x30);
        o.putU64(cast(ulong) v.num ^ 0x8000_0000_0000_0000UL);
        return true;
    case Kind.string_:
        o.put(0x40);
        foreach (char c; v.str)
        {
            o.put(cast(ubyte) c);
            if (c == 0)
                o.put(0xFF);
        }
        o.put(0);
        o.put(0);
        return true;
    case Kind.list:
    case Kind.object:
        return false;
    }
}

/// The `vkey` of a scalar value.
ubyte[] vkey(Value v) pure nothrow @safe
{
    ByteBuffer b;
    appendVkey(b, v);
    return b.data.dup;
}

/// Length of the `vkey` at the start of an index key.
size_t vkeyLength(const(ubyte)[] k) pure nothrow @nogc @safe
{
    switch (k[0])
    {
    case 0x30:
        return 9;
    case 0x40:
        size_t i = 1;
        while (true)
        {
            if (k[i] == 0)
            {
                if (k[i + 1] == 0xFF)
                    i += 2;
                else
                    return i + 2;
            }
            else
                i++;
        }
    default:
        return 1;
    }
}

/// The index entry key for `doc` stored under `docKey` at `segments`, or null
/// when the document is not indexable there.
ubyte[] makeIndexKey(Value doc, const string[] segments, const(ubyte)[] docKey) pure nothrow @safe
{
    auto v = resolvePath(doc, segments);
    if (v is null)
        return null;
    ByteBuffer b;
    if (!appendVkey(b, *v))
        return null;
    b.put(docKey);
    return b.data.dup;
}

/// The entry keys of `doc` for every live index.
IndexKeys computeIndexKeys(const ref Header h, Value doc, const(ubyte)[] docKey) pure nothrow @safe
{
    IndexKeys r;
    foreach (s, ref slot; h.slots)
        if (slot.live)
            r[s] = makeIndexKey(doc, slot.segments, docKey);
    return r;
}

/// Throw `indexKeyTooLong` when any key is over the limit.
void checkIndexKeys(const ref IndexKeys keys) pure @safe
{
    foreach (k; keys)
        if (k.length > maxIndexKey)
            fail(ErrorKind.indexKeyTooLong);
}

/// Bring every live index from the old entry keys to the new ones, in slot
/// order (§14.3).
void applyIndexChanges(Pager pg, const ref IndexKeys oldKeys, const ref IndexKeys newKeys)
{
    foreach (s; 0 .. maxIndexes)
    {
        if (!pg.header.slots[s].live)
            continue;
        auto o = oldKeys[s];
        auto w = newKeys[s];
        auto tree = TreeRef.indexTree(s);
        if (o is null && w is null)
            continue;
        if (o !is null && w !is null)
        {
            if (o == w)
                continue;
            remove(pg, tree, o);
            insert(pg, tree, Cell(w));
        }
        else if (w !is null)
        {
            insert(pg, tree, Cell(w));
            pg.header.slots[s].entries++;
        }
        else
        {
            remove(pg, tree, o);
            pg.header.slots[s].entries--;
        }
    }
}

/// `create index` (§14.4). Returns the number of entries.
uint createIndex(Pager pg, const string[] segments)
{
    immutable text = joinPath(segments);
    foreach (ref s; pg.header.slots)
        if (s.live && s.path == text)
            fail(ErrorKind.indexExists);
    if (pg.header.indexCount >= maxIndexes)
        fail(ErrorKind.indexLimit);
    ubyte[][] keys;
    for (auto c = first(pg, TreeRef.primaryTree); c.valid; c.next())
    {
        auto doc = loadDocument(pg, c);
        auto k = makeIndexKey(doc, segments, c.key);
        if (k is null)
            continue;
        if (k.length > maxIndexKey)
            fail(ErrorKind.indexKeyTooLong);
        keys ~= k;
    }
    size_t slot = 0;
    while (pg.header.slots[slot].live)
        slot++;
    auto sl = &pg.header.slots[slot];
    sl.live = true;
    sl.path = text;
    sl.segments = segments.dup;
    sl.root = 0;
    sl.entries = 0;
    pg.header.indexCount++;
    foreach (k; keys)
    {
        insert(pg, TreeRef.indexTree(slot), Cell(k));
        pg.header.slots[slot].entries++;
    }
    return cast(uint) keys.length;
}

/// `drop index` (§14.5). Returns the number of pages freed.
uint dropIndex(Pager pg, const string[] segments)
{
    immutable text = joinPath(segments);
    foreach (s, ref slot; pg.header.slots)
        if (slot.live && slot.path == text)
        {
            immutable freed = freeTree(pg, slot.root);
            pg.header.slots[s] = IndexSlot.init;
            pg.header.indexCount--;
            return freed;
        }
    fail(ErrorKind.indexMissing);
}

/// Primary keys of the index entries in the candidate range of §17.3 for
/// `op` and the `vkey` of its right-hand side. They are returned in the order
/// the index yields them (for `==`, already ascending).
const(ubyte)[][] candidateKeys(Pager pg, size_t slot, CmpOp op, const(ubyte)[] v)
{
    const(ubyte)[][] out_;
    auto tree = TreeRef.indexTree(slot);
    Cursor c;
    final switch (op)
    {
    case CmpOp.eq:
        for (c = seek(pg, tree, v); c.valid && startsWith(c.key, v); c.next())
            out_ ~= c.key[vkeyLength(c.key) .. $];
        break;
    case CmpOp.lt:
        for (c = first(pg, tree); c.valid && compareBytes(c.key, v) < 0; c.next())
            out_ ~= c.key[vkeyLength(c.key) .. $];
        break;
    case CmpOp.le:
        for (c = first(pg, tree); c.valid && (compareBytes(c.key, v) < 0 || startsWith(c.key, v)); c.next())
            out_ ~= c.key[vkeyLength(c.key) .. $];
        break;
    case CmpOp.gt:
        c = seek(pg, tree, v);
        while (c.valid && startsWith(c.key, v))
            c.next();
        for (; c.valid; c.next())
            out_ ~= c.key[vkeyLength(c.key) .. $];
        break;
    case CmpOp.ge:
        for (c = seek(pg, tree, v); c.valid; c.next())
            out_ ~= c.key[vkeyLength(c.key) .. $];
        break;
    case CmpOp.ne:
        assert(0, "`!=` is never a candidate range");
    }
    return out_;
}
