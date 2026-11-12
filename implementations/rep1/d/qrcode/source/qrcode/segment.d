/// Mode selection, version selection and the data bit stream of a single segment.
module qrcode.segment;

import qrcode.bitbuffer;
import qrcode.tables;

/// Data encoding mode.
enum Mode : ubyte
{
    numeric,      /// ASCII digits only
    alphanumeric, /// the 45-character QR alphanumeric set
    byte_,        /// raw bytes
}

/// The 45 characters of alphanumeric mode, in value order.
immutable string alphanumericCharset = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

/// Raised when the payload does not fit in any version at the requested level.
class DataTooLongException : Exception
{
    this(string msg = "data too long for any QR code version at this error correction level",
         string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Value of `c` in the alphanumeric set, or -1 if it is not a member.
int alphanumericValue(ubyte c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'Z') return c - 'A' + 10;
    switch (c)
    {
    case ' ': return 36;
    case '$': return 37;
    case '%': return 38;
    case '*': return 39;
    case '+': return 40;
    case '-': return 41;
    case '.': return 42;
    case '/': return 43;
    case ':': return 44;
    default: return -1;
    }
}

/// Picks the most compact applicable mode: numeric, then alphanumeric, then byte.
Mode selectMode(const(ubyte)[] data) @safe pure nothrow @nogc
{
    bool numeric = true;
    bool alnum = true;
    foreach (c; data)
    {
        if (c < '0' || c > '9')
            numeric = false;
        if (alphanumericValue(c) < 0)
            alnum = false;
    }
    return numeric ? Mode.numeric : alnum ? Mode.alphanumeric : Mode.byte_;
}

/// Width in bits of the character count indicator.
int charCountBits(Mode mode, int ver) @safe pure nothrow @nogc
in (ver >= minVersion && ver <= maxVersion)
{
    static immutable ubyte[3][3] widths = [
        [10, 12, 14], // numeric
        [9, 11, 13],  // alphanumeric
        [8, 16, 16],  // byte
    ];
    return widths[mode][ver <= 9 ? 0 : ver <= 26 ? 1 : 2];
}

/// Number of data bits (excluding mode and count indicators) for `n` characters.
size_t dataBitLength(Mode mode, size_t n) @safe pure nothrow @nogc
{
    final switch (mode)
    {
    case Mode.numeric:
        static immutable ubyte[3] tail = [0, 4, 7];
        return 10 * (n / 3) + tail[n % 3];
    case Mode.alphanumeric:
        return 11 * (n / 2) + 6 * (n % 2);
    case Mode.byte_:
        return 8 * n;
    }
}

/// Smallest version at `ecl` whose capacity holds `n` characters of `mode`.
/// Throws `DataTooLongException` if there is none.
int chooseVersion(Mode mode, size_t n, Ecl ecl) @safe pure
{
    const bits = dataBitLength(mode, n);
    foreach (v; minVersion .. maxVersion + 1)
    {
        if (4 + charCountBits(mode, v) + bits <= 8 * cast(size_t) dataCodewords(v, ecl))
            return v;
    }
    throw new DataTooLongException;
}

/// Four-bit mode indicator.
private uint modeIndicator(Mode mode) @safe pure nothrow @nogc
{
    final switch (mode)
    {
    case Mode.numeric: return 1;
    case Mode.alphanumeric: return 2;
    case Mode.byte_: return 4;
    }
}

/// Appends the mode indicator, character count and data bits of one segment.
void appendSegment(ref BitBuffer buf, const(ubyte)[] data, Mode mode, int ver) @safe pure nothrow
{
    buf.append(modeIndicator(mode), 4);
    buf.append(cast(uint) data.length, charCountBits(mode, ver));
    final switch (mode)
    {
    case Mode.numeric:
        for (size_t i = 0; i < data.length; i += 3)
        {
            const take = data.length - i < 3 ? data.length - i : 3;
            uint v = 0;
            foreach (c; data[i .. i + take])
                v = v * 10 + (c - '0');
            buf.append(v, take == 3 ? 10 : take == 2 ? 7 : 4);
        }
        break;
    case Mode.alphanumeric:
        for (size_t i = 0; i < data.length; i += 2)
        {
            if (i + 1 < data.length)
                buf.append(cast(uint)(45 * alphanumericValue(data[i]) + alphanumericValue(data[i + 1])), 11);
            else
                buf.append(cast(uint) alphanumericValue(data[i]), 6);
        }
        break;
    case Mode.byte_:
        foreach (c; data)
            buf.append(c, 8);
        break;
    }
}

/// Adds the terminator, byte-alignment and 0xEC/0x11 padding so that `buf` holds exactly `capacity` data codewords.
void terminateAndPad(ref BitBuffer buf, size_t capacity) @safe pure nothrow
in (buf.length <= 8 * capacity)
{
    const room = 8 * capacity - buf.length;
    buf.appendZeros(room < 4 ? room : 4);
    buf.appendZeros((8 - buf.length % 8) % 8);
    for (ubyte pad = 0xEC; buf.length < 8 * capacity; pad ^= 0xEC ^ 0x11)
        buf.append(pad, 8);
}

@safe pure nothrow @nogc unittest
{
    assert(selectMode(cast(const(ubyte)[]) "0123456789") == Mode.numeric);
    assert(selectMode(cast(const(ubyte)[]) "HELLO WORLD $%*+-./:") == Mode.alphanumeric);
    assert(selectMode(cast(const(ubyte)[]) "Hello") == Mode.byte_);
    assert(selectMode(cast(const(ubyte)[]) "A\x7f") == Mode.byte_);
}

@safe pure nothrow @nogc unittest
{
    assert(dataBitLength(Mode.numeric, 8) == 27);
    assert(dataBitLength(Mode.numeric, 7) == 24);
    assert(dataBitLength(Mode.alphanumeric, 11) == 61);
    assert(dataBitLength(Mode.byte_, 6) == 48);
    assert(charCountBits(Mode.byte_, 9) == 8 && charCountBits(Mode.byte_, 10) == 16);
    assert(charCountBits(Mode.numeric, 27) == 14);
}

@safe pure unittest
{
    import std.exception : assertThrown;
    // Capacity limits from the specification at version 40.
    assert(chooseVersion(Mode.numeric, 7089, Ecl.low) == 40);
    assert(chooseVersion(Mode.alphanumeric, 1852, Ecl.high) == 40);
    assert(chooseVersion(Mode.byte_, 2953, Ecl.low) == 40);
    assertThrown!DataTooLongException(chooseVersion(Mode.byte_, 2954, Ecl.low));
    assert(chooseVersion(Mode.byte_, 1, Ecl.high) == 1);
}

@safe pure unittest
{
    // Worked example 1: "HELLO WORLD" in version 1-M.
    BitBuffer b;
    appendSegment(b, cast(const(ubyte)[]) "HELLO WORLD", Mode.alphanumeric, 1);
    terminateAndPad(b, 16);
    assert(b.bytes == [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17]);
}
