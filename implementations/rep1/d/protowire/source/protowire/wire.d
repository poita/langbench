/// Low-level wire-format primitives: varints, tags, zigzag, and a bounds-checked reader.
module protowire.wire;

import protowire.errors : WireException;

/// Protobuf wire types.
enum WireType : ubyte
{
    varint = 0,
    fixed64 = 1,
    lengthDelimited = 2,
    startGroup = 3,
    endGroup = 4,
    fixed32 = 5,
}

/// Maximum encoded size of a varint value.
enum maxVarintBytes = 10;
/// Maximum encoded size of a tag on decode.
enum maxTagBytes = 5;
/// Maximum encoded size of a length prefix on decode.
enum maxLengthBytes = 5;

/// ZigZag-encodes a 32-bit signed value.
uint zigzag32(int v) @safe pure nothrow @nogc
{
    return cast(uint)((v << 1) ^ (v >> 31));
}

/// ZigZag-encodes a 64-bit signed value.
ulong zigzag64(long v) @safe pure nothrow @nogc
{
    return cast(ulong)((v << 1) ^ (v >> 63));
}

/// Inverse of `zigzag32`.
int unzigzag32(uint u) @safe pure nothrow @nogc
{
    return cast(int)((u >> 1) ^ (0u - (u & 1)));
}

/// Inverse of `zigzag64`.
long unzigzag64(ulong u) @safe pure nothrow @nogc
{
    return cast(long)((u >> 1) ^ (0UL - (u & 1)));
}

/// Number of bytes in the minimal varint encoding of `v` (1..10).
size_t varintSize(ulong v) @safe pure nothrow @nogc
{
    size_t n = 1;
    while (v >= 0x80)
    {
        v >>= 7;
        ++n;
    }
    return n;
}

/// Writes the minimal varint encoding of `v` at `buf[pos..]` and returns the new position.
size_t putVarint(scope ubyte[] buf, size_t pos, ulong v) @safe pure nothrow @nogc
{
    while (v >= 0x80)
    {
        buf[pos++] = cast(ubyte)(v | 0x80);
        v >>= 7;
    }
    buf[pos++] = cast(ubyte) v;
    return pos;
}

/// A decoded tag.
struct Tag
{
    uint fieldNumber;
    WireType wireType;
}

/// A cursor over a byte slice that throws `WireException` instead of reading out of bounds.
struct Reader
{
    const(ubyte)[] data;
    size_t pos;

    this(const(ubyte)[] data) @safe pure nothrow @nogc
    {
        this.data = data;
    }

    /// True when all bytes have been consumed.
    bool empty() const @safe pure nothrow @nogc
    {
        return pos >= data.length;
    }

    /// Number of unread bytes.
    size_t remaining() const @safe pure nothrow @nogc
    {
        return data.length - pos;
    }

    /// Reads a varint of at most `maxBytes` bytes. Bits beyond bit 63 are discarded.
    ulong readVarint(size_t maxBytes = maxVarintBytes) @safe pure
    {
        ulong result = 0;
        foreach (i; 0 .. maxBytes)
        {
            if (pos >= data.length)
                throw new WireException("truncated varint");
            immutable b = data[pos++];
            result |= cast(ulong)(b & 0x7f) << (7 * i);
            if (!(b & 0x80))
                return result;
        }
        throw new WireException("varint too long");
    }

    /// Reads and validates a tag. An end-group tag is returned as such; the
    /// caller decides whether it is legal.
    Tag readTag() @safe pure
    {
        immutable v = readVarint(maxTagBytes);
        if (v >> 32)
            throw new WireException("tag out of range");
        immutable field = cast(uint)(v >> 3);
        immutable wt = cast(uint)(v & 7);
        if (field == 0)
            throw new WireException("field number 0");
        if (wt > 5)
            throw new WireException("invalid wire type");
        return Tag(field, cast(WireType) wt);
    }

    /// Reads a length prefix and checks it against the remaining bytes.
    size_t readLength() @safe pure
    {
        immutable v = readVarint(maxLengthBytes);
        if (v > remaining)
            throw new WireException("length exceeds remaining data");
        return cast(size_t) v;
    }

    /// Reads `n` raw bytes.
    const(ubyte)[] readBytes(size_t n) @safe pure
    {
        if (n > remaining)
            throw new WireException("truncated data");
        auto r = data[pos .. pos + n];
        pos += n;
        return r;
    }

    /// Reads a length prefix followed by that many bytes.
    const(ubyte)[] readLengthDelimited() @safe pure
    {
        return readBytes(readLength());
    }

    /// Reads a little-endian 32-bit value.
    uint readFixed32() @safe pure
    {
        auto b = readBytes(4);
        return b[0] | (b[1] << 8) | (b[2] << 16) | (cast(uint) b[3] << 24);
    }

    /// Reads a little-endian 64-bit value.
    ulong readFixed64() @safe pure
    {
        auto b = readBytes(8);
        ulong v = 0;
        foreach (i; 0 .. 8)
            v |= cast(ulong) b[i] << (8 * i);
        return v;
    }

    /// Skips the value that follows a tag with the given wire type, without
    /// interpreting it. Groups are skipped iteratively up to their matching end tag.
    void skipValue(Tag tag) @safe pure
    {
        final switch (tag.wireType)
        {
        case WireType.varint:
            readVarint();
            break;
        case WireType.fixed64:
            readBytes(8);
            break;
        case WireType.fixed32:
            readBytes(4);
            break;
        case WireType.lengthDelimited:
            readBytes(readLength());
            break;
        case WireType.startGroup:
            skipGroup(tag.fieldNumber);
            break;
        case WireType.endGroup:
            throw new WireException("unexpected end group");
        }
    }

    // Skips the body of a group (and its end tag), whose start tag carried `field`.
    private void skipGroup(uint field) @safe pure
    {
        uint[] open = [field];
        while (open.length)
        {
            immutable t = readTag();
            final switch (t.wireType)
            {
            case WireType.startGroup:
                open ~= t.fieldNumber;
                break;
            case WireType.endGroup:
                if (t.fieldNumber != open[$ - 1])
                    throw new WireException("mismatched end group");
                open.length = open.length - 1;
                break;
            case WireType.varint:
            case WireType.fixed64:
            case WireType.fixed32:
            case WireType.lengthDelimited:
                skipValue(t);
                break;
            }
        }
    }
}

@safe pure unittest
{
    assert(varintSize(0) == 1 && varintSize(127) == 1 && varintSize(128) == 2);
    assert(varintSize(ulong.max) == 10);
    ubyte[10] buf;
    assert(putVarint(buf[], 0, 300) == 2 && buf[0 .. 2] == [0xac, 0x02]);
    assert(putVarint(buf[], 0, ulong.max) == 10 && buf[9] == 0x01);
}

@safe pure unittest
{
    assert(zigzag32(0) == 0 && zigzag32(-1) == 1 && zigzag32(1) == 2);
    assert(zigzag32(int.min) == uint.max);
    assert(zigzag64(long.min) == ulong.max);
    foreach (v; [0, 1, -1, 2, -2, int.max, int.min])
        assert(unzigzag32(zigzag32(v)) == v);
    foreach (v; [0L, 1, -1, long.max, long.min])
        assert(unzigzag64(zigzag64(v)) == v);
}

@safe pure unittest
{
    import std.exception : assertThrown;

    // 10-byte forms, discarding bits beyond 63
    assert(Reader([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f]).readVarint() == ulong.max);
    assert(Reader([0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02]).readVarint() == 0);
    // non-minimal accepted
    assert(Reader([0x81, 0x00]).readVarint() == 1);
    // too long / truncated
    assertThrown!WireException(Reader([0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00]).readVarint());
    assertThrown!WireException(Reader([0xff]).readVarint());
    // tags
    assert(Reader([0x08]).readTag() == Tag(1, WireType.varint));
    assertThrown!WireException(Reader([0x00]).readTag());       // field 0
    assertThrown!WireException(Reader([0x0e]).readTag());       // wire type 6
    assertThrown!WireException(Reader([0x80, 0x80, 0x80, 0x80, 0x10]).readTag()); // >= 2^32
    assertThrown!WireException(Reader([0x88, 0x80, 0x80, 0x80, 0x80, 0x00]).readTag()); // 6 bytes
    // lengths
    assertThrown!WireException(Reader([0x05, 0x00]).readLengthDelimited());
    assertThrown!WireException(Reader([0x80, 0x80, 0x80, 0x80, 0x80, 0x00]).readLength());
}

@safe pure unittest
{
    import std.exception : assertThrown;

    // group 3 containing a varint and a nested group 4, then a trailing byte
    auto r = Reader([0x1b, 0x08, 0x01, 0x23, 0x24, 0x1c, 0x42]);
    auto t = r.readTag();
    assert(t == Tag(3, WireType.startGroup));
    r.skipValue(t);
    assert(r.remaining == 1);

    auto bad = Reader([0x1b, 0x14]);
    assertThrown!WireException(bad.skipValue(bad.readTag()));
    auto open = Reader([0x1b, 0x08, 0x01]);
    assertThrown!WireException(open.skipValue(open.readTag()));
}
