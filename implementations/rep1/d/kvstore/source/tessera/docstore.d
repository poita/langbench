/// Documents in the primary tree: inline bytes in the leaf cell, the rest in
/// a chain of overflow pages.
module tessera.docstore;

import tessera.bytes;
import tessera.btree;
import tessera.constants;
import tessera.node;
import tessera.pager;
import tessera.value;

/// Build the primary leaf cell for `key` holding the serialised document
/// `ser`, allocating its overflow chain (in chain order) when it is longer
/// than `maxInline` bytes. The chain pages are written; the cell is not.
Cell buildCell(Pager pg, const(ubyte)[] key, const(ubyte)[] ser)
{
    Cell c;
    c.key = key;
    c.docLen = cast(uint) ser.length;
    if (ser.length <= maxInline)
    {
        c.data = ser;
        return c;
    }
    c.data = ser[0 .. maxInline];
    auto rest = ser[maxInline .. $];
    immutable n = (rest.length + overflowPayload - 1) / overflowPayload;
    auto pages = new uint[n];
    foreach (ref p; pages)
        p = pg.allocate();
    foreach (i, p; pages)
    {
        immutable from = i * overflowPayload;
        immutable to = from + overflowPayload < rest.length ? from + overflowPayload : rest.length;
        auto img = new ubyte[pageSize];
        img[0] = typeOverflow;
        setU32(img, 4, i + 1 < n ? pages[i + 1] : 0);
        setU16(img, 8, cast(uint)(to - from));
        img[12 .. 12 + (to - from)] = rest[from .. to];
        pg.write(p, img);
    }
    c.overflow = pages[0];
    return c;
}

/// The serialised document under a primary-tree cursor.
const(ubyte)[] readDocumentBytes(const Pager pg, const ref Cursor cur) nothrow
{
    auto inl = cur.inlineData;
    immutable first = cur.overflow;
    if (first == 0)
        return inl;
    auto doc = new ubyte[cur.docLen];
    doc[0 .. inl.length] = inl[];
    size_t at = inl.length;
    uint p = first;
    while (p != 0)
    {
        auto img = pg.read(p);
        immutable len = getU16(img, 8);
        doc[at .. at + len] = img[12 .. 12 + len];
        at += len;
        p = getU32(img, 4);
    }
    return doc;
}

/// The deserialised document under a primary-tree cursor.
Value loadDocument(const Pager pg, const ref Cursor cur)
{
    return deserialize(readDocumentBytes(pg, cur));
}

/// Free an overflow chain, first page first.
void freeChain(Pager pg, uint first)
{
    uint p = first;
    while (p != 0)
    {
        immutable next = getU32(pg.read(p), 4);
        pg.free(p);
        p = next;
    }
}
