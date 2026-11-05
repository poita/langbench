/// Test helper: assembles tiny SQLite database images byte by byte, so the
/// unit tests do not depend on any external file or on a SQLite library.
module dbbuilder;

import sqlitefile.value;

@safe:

/// Encodes `v` as a SQLite varint.
ubyte[] varint(long value)
{
    ulong v = cast(ulong) value;
    if (v > 0x00ff_ffff_ffff_ffffUL)
    {
        ubyte[] r = new ubyte[9];
        r[8] = cast(ubyte)(v & 0xff);
        v >>= 8;
        foreach_reverse (i; 0 .. 8)
        {
            r[i] = cast(ubyte)((v & 0x7f) | (i < 8 ? 0x80 : 0));
            v >>= 7;
        }
        return r;
    }
    ubyte[] tmp = [cast(ubyte)(v & 0x7f)];
    v >>= 7;
    while (v)
    {
        tmp = cast(ubyte)((v & 0x7f) | 0x80) ~ tmp;
        v >>= 7;
    }
    return tmp;
}

ubyte[] be32(uint v)
{
    return [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];
}

/// Encodes a record from values (integers always use the 8-byte form unless 0/1).
ubyte[] record(const Value[] vals)
{
    ubyte[] types, body_;
    foreach (v; vals)
    {
        final switch (v.kind)
        {
        case ValueKind.null_:
            types ~= varint(0);
            break;
        case ValueKind.integer:
            if (v.i == 0 || v.i == 1)
                types ~= varint(8 + v.i);
            else
            {
                types ~= varint(6);
                foreach_reverse (i; 0 .. 8)
                    body_ ~= cast(ubyte)(cast(ulong) v.i >> (8 * i));
            }
            break;
        case ValueKind.real_:
            types ~= varint(7);
            union U
            {
                double d;
                ulong u;
            }

            U x;
            x.d = v.r;
            foreach_reverse (i; 0 .. 8)
                body_ ~= cast(ubyte)(x.u >> (8 * i));
            break;
        case ValueKind.text:
            types ~= varint(13 + 2 * cast(long) v.bytes.length);
            body_ ~= v.bytes;
            break;
        case ValueKind.blob:
            types ~= varint(12 + 2 * cast(long) v.bytes.length);
            body_ ~= v.bytes;
            break;
        }
    }
    auto hs = types.length + 1; // header sizes under 128 only
    assert(hs < 128);
    return varint(hs) ~ types ~ body_;
}

ubyte[] tableLeafCell(long rowid, const(ubyte)[] payload, const(ubyte)[] overflowTail = null)
{
    return varint(payload.length) ~ varint(rowid) ~ payload ~ overflowTail;
}

ubyte[] tableInteriorCell(uint child, long key)
{
    return be32(child) ~ varint(key);
}

ubyte[] indexLeafCell(const(ubyte)[] payload)
{
    return varint(payload.length) ~ payload;
}

ubyte[] indexInteriorCell(uint child, const(ubyte)[] payload)
{
    return be32(child) ~ varint(payload.length) ~ payload;
}

/// Builds one B-tree page of `pageSize` bytes. `first` is 100 for page 1.
ubyte[] btreePage(uint pageSize, ubyte type, const(ubyte)[][] cells, uint rightChild = 0, size_t first = 0)
{
    auto p = new ubyte[pageSize];
    immutable interior = type == 0x02 || type == 0x05;
    p[first] = type;
    p[first + 3] = cast(ubyte)(cells.length >> 8);
    p[first + 4] = cast(ubyte) cells.length;
    if (interior)
        p[first + 8 .. first + 12] = be32(rightChild);
    size_t arr = first + (interior ? 12 : 8);
    size_t top = pageSize;
    foreach (i, c; cells)
    {
        top -= c.length;
        p[top .. top + c.length] = c[];
        p[arr + 2 * i] = cast(ubyte)(top >> 8);
        p[arr + 2 * i + 1] = cast(ubyte) top;
    }
    return p;
}

/// Concatenates pages; page 1 gets the database header.
ubyte[] assemble(uint pageSize, ubyte[][] pages)
{
    ubyte[] img;
    foreach (p; pages)
        img ~= p;
    img[0 .. 16] = cast(const(ubyte)[]) "SQLite format 3\0";
    img[16] = cast(ubyte)(pageSize >> 8);
    img[17] = cast(ubyte) pageSize;
    img[18] = 1;
    img[19] = 1;
    img[28 .. 32] = be32(cast(uint) pages.length);
    img[56 .. 60] = be32(1);
    return img;
}

/// A schema-table row record.
ubyte[] schemaRow(string type, string name, string tbl, long root, string sql)
{
    return record([Value.makeText(type), Value.makeText(name), Value.makeText(tbl),
            Value.makeInt(root), sql is null ? Value.makeNull() : Value.makeText(sql)]);
}
