/// Decoding of SQLite records (table rows and index entries), SPEC §1.8.
module sqlitefile.record;

import sqlitefile.bytes;
import sqlitefile.errors;
import sqlitefile.value;

@safe:

/// Size in bytes of the body of a value with the given serial type.
size_t serialTypeSize(ulong t) pure nothrow @nogc
{
    static immutable ubyte[10] fixed = [0, 1, 2, 3, 4, 6, 8, 8, 0, 0];
    if (t < 10)
        return fixed[cast(size_t) t];
    if (t < 12)
        return 0; // reserved
    return cast(size_t)((t - 12) / 2);
}

/// Decodes the first `dst.length` columns of `payload` into `dst`; columns the
/// record does not have are set to NULL. Returns the number of columns the
/// record actually contains.
///
/// TEXT and BLOB values alias `payload`.
size_t decodeRecord(const(ubyte)[] payload, Value[] dst)
{
    long headerSize;
    size_t hpos = readVarint(payload, 0, headerSize);
    if (headerSize < hpos || cast(ulong) headerSize > payload.length)
        throw new FormatException("bad record header size");
    const hend = cast(size_t) headerSize;
    size_t bpos = hend;
    size_t col = 0;
    while (hpos < hend)
    {
        long st;
        hpos += readVarint(payload, hpos, st);
        if (st < 0)
            throw new FormatException("bad serial type");
        if (col < dst.length)
        {
            dst[col] = decodeValue(payload, bpos, cast(ulong) st);
            bpos += serialTypeSize(cast(ulong) st);
        }
        col++;
    }
    foreach (k; col .. dst.length)
        dst[k] = Value.makeNull();
    return col;
}

/// Decodes every column of `payload`.
Value[] decodeAll(const(ubyte)[] payload)
{
    long headerSize;
    size_t hpos = readVarint(payload, 0, headerSize);
    if (headerSize < hpos || cast(ulong) headerSize > payload.length)
        throw new FormatException("bad record header size");
    // The number of columns is at most the number of header bytes.
    auto vals = new Value[cast(size_t) headerSize - hpos];
    const n = decodeRecord(payload, vals);
    return vals[0 .. n];
}

private Value decodeValue(const(ubyte)[] p, size_t pos, ulong st)
{
    switch (st)
    {
    case 0:
        return Value.makeNull();
    case 1: .. case 6:
        return Value.fromInt(readSigned(p, pos, serialTypeSize(st)));
    case 7:
        {
            union Bits
            {
                ulong u;
                double d;
            }

            Bits b;
            b.u = cast(ulong) readSigned(p, pos, 8);
            return Value.fromReal(b.d);
        }
    case 8:
        return Value.fromInt(0);
    case 9:
        return Value.fromInt(1);
    case 10, 11:
        throw new FormatException("reserved serial type");
    default:
        const n = serialTypeSize(st);
        checkRange(p, pos, n);
        return (st & 1) ? Value.fromText(p[pos .. pos + n]) : Value.fromBlob(p[pos .. pos + n]);
    }
}

unittest
{
    // header: size 7, types: 1(int8) 9(one) 0(null) 7(real) 17 (text len 2)... build by hand
    ubyte[] rec = [
        6, // header size (1 + 5 serial types)
        1, 9, 0, 19, 12, // int8, const-1, null, text(3), blob(0)
        0xfe, // -2
        'a', 'b', 'c',
    ];
    Value[5] v;
    assert(decodeRecord(rec, v[]) == 5);
    assert(v[0].type == ValueType.integer && v[0].i == -2);
    assert(v[1].type == ValueType.integer && v[1].i == 1);
    assert(v[2].isNull);
    assert(v[3].type == ValueType.text && v[3].bytes == cast(const(ubyte)[]) "abc");
    assert(v[4].type == ValueType.blob && v[4].bytes.length == 0);
}

unittest
{
    // Fewer values than requested columns: the rest read as NULL.
    ubyte[] rec = [2, 8];
    Value[3] v;
    assert(decodeRecord(rec, v[]) == 1);
    assert(v[0].i == 0 && v[1].isNull && v[2].isNull);
    // All columns, with a REAL (3.5 = 0x400C000000000000) and a 6-byte int.
    ubyte[] rec2 = [3, 7, 5, 0x40, 0x0c, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0];
    auto all = decodeAll(rec2);
    assert(all.length == 2);
    assert(all[0].r == 3.5);
    assert(all[1].i == 256);
}

unittest
{
    import std.exception : assertThrown;

    Value[1] v;
    assertThrown!FormatException(decodeRecord([cast(ubyte) 9, 1], v[]));
    assertThrown!FormatException(decodeRecord([cast(ubyte) 2, 10], v[]));
    assertThrown!FormatException(decodeRecord([cast(ubyte) 2, 15], v[])); // body missing
}
