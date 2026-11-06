/// Decoding of SQLite records (table rows and index entries).
module sqlitefile.record;

import sqlitefile.bytes;
import sqlitefile.errors;
import sqlitefile.value;

@safe:

/// Size in bytes of the body of a value with serial type `t`.
size_t serialSize(ulong t) pure
{
    switch (t)
    {
    case 0, 8, 9:
        return 0;
    case 1, 2, 3, 4:
        return cast(size_t) t;
    case 5:
        return 6;
    case 6, 7:
        return 8;
    case 10, 11:
        throw new FormatException("reserved serial type");
    default:
        return cast(size_t)((t - 12) / 2);
    }
}

/// Lazily decodes one record.
///
/// `parse` reads only the header (serial types and body offsets) into
/// internal arrays that are reused from record to record; `value` then
/// decodes a single column on demand. TEXT and BLOB values are views into the
/// record bytes.
struct RecordReader
{
    private const(ubyte)[] rec;
    private ulong[] types;
    private size_t[] offsets;
    private size_t n;

    /// Number of columns the record actually stores.
    size_t length() const pure nothrow @nogc
    {
        return n;
    }

    /// Reads the header of `record`.
    void parse(const(ubyte)[] record) pure
    {
        rec = record;
        n = 0;
        if (record.length == 0)
            return;
        size_t pos = 0;
        immutable hs = readVarint(record, pos);
        if (hs < 1 || hs > record.length)
            throw new FormatException("bad record header size");
        size_t off = cast(size_t) hs;
        while (pos < hs)
        {
            immutable t = cast(ulong) readVarint(record, pos);
            if (n == types.length)
            {
                immutable cap = n < 8 ? 8 : n * 2;
                types.length = cap;
                offsets.length = cap;
            }
            types[n] = t;
            offsets[n] = off;
            off += serialSize(t);
            n++;
        }
        if (off > record.length)
            throw new FormatException("record body is truncated");
    }

    /// The serial type of column `i`.
    ulong serialType(size_t i) const pure nothrow @nogc
    {
        return types[i];
    }

    /// Decodes column `i`; columns past the end of the record read as NULL.
    Value value(size_t i) const pure
    {
        if (i >= n)
            return Value.makeNull();
        immutable t = types[i];
        immutable off = offsets[i];
        switch (t)
        {
        case 0:
            return Value.makeNull();
        case 8:
            return Value.makeInt(0);
        case 9:
            return Value.makeInt(1);
        case 1, 2, 3, 4, 6:
            return Value.makeInt(readSignedBE(rec, off, serialSize(t)));
        case 5:
            return Value.makeInt(readSignedBE(rec, off, 6));
        case 7:
            return Value.makeReal(bitsToDouble(readBE64(rec, off)));
        default:
            immutable size = serialSize(t);
            auto bytes = rec[off .. off + size];
            return (t & 1) ? Value.makeText(bytes) : Value.makeBlob(bytes);
        }
    }
}

private double bitsToDouble(ulong bits) pure nothrow @nogc
{
    union U
    {
        ulong u;
        double d;
    }

    U x;
    x.u = bits;
    return x.d;
}
