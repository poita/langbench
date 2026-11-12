/// Documents in primary leaf cells and their overflow chains (SPEC §9, §11.3).
module tessera.overflow;

import tessera.bytes;
import tessera.constants;
import tessera.node;
import tessera.pager;

/// Build the primary leaf cell for `key` holding the serialised document
/// `doc`. Overflow pages for everything past the first 192 bytes are
/// allocated now, first chunk first (SPEC §14.3 step 2).
Cell buildCell(Pager pg, const(ubyte)[] key, const(ubyte)[] doc)
{
    Cell c;
    c.key = key;
    c.docLen = cast(uint) doc.length;
    if (doc.length <= MAX_INLINE)
    {
        c.inline = doc;
        return c;
    }
    c.inline = doc[0 .. MAX_INLINE];
    auto rest = doc[MAX_INLINE .. $];
    immutable chunks = (rest.length + OVF_PAYLOAD - 1) / OVF_PAYLOAD;
    auto pages = new uint[chunks];
    foreach (ref p; pages)
        p = pg.allocate();
    foreach (i, p; pages)
    {
        auto chunk = rest[i * OVF_PAYLOAD .. (i + 1) * OVF_PAYLOAD > rest.length
            ? rest.length : (i + 1) * OVF_PAYLOAD];
        auto img = new ubyte[PAGE_SIZE];
        img[0] = PageType.overflow;
        putU32(img, 4, i + 1 < chunks ? pages[i + 1] : 0);
        putU16(img, 8, cast(uint) chunk.length);
        img[12 .. 12 + chunk.length] = chunk[];
        pg.writePage(p, img);
    }
    c.overflow = pages[0];
    return c;
}

/// The whole serialised document of a primary leaf cell.
ubyte[] readDocument(Pager pg, ref const Cell c)
{
    auto buf = new ubyte[c.docLen];
    buf[0 .. c.inline.length] = c.inline[];
    size_t pos = c.inline.length;
    uint p = c.overflow;
    while (p != 0)
    {
        auto page = pg.readPage(p);
        immutable len = getU16(page, 8);
        buf[pos .. pos + len] = page[12 .. 12 + len];
        pos += len;
        p = getU32(page, 4);
    }
    return buf;
}

/// Free a cell's overflow chain, first page first (SPEC §9).
void freeChain(Pager pg, uint first)
{
    uint p = first;
    while (p != 0)
    {
        immutable next = getU32(pg.readPage(p), 4);
        pg.free(p);
        p = next;
    }
}
