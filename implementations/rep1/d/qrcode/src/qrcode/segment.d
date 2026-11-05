/**
 * Mode selection, version selection and data-codeword packing for a
 * single-segment payload.
 */
module qrcode.segment;

import qrcode.bitbuffer;
import qrcode.tables;

/// Data encoding mode.
enum Mode : ubyte
{
    numeric,
    alphanumeric,
    byteMode,
}

/// The characters of the alphanumeric set; the index is the character value.
enum alphanumericCharset = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

private ubyte[256] buildAlnumTable() @safe pure nothrow @nogc
{
    ubyte[256] t;
    t[] = 0xFF;
    foreach (i, c; alphanumericCharset)
        t[c] = cast(ubyte) i;
    return t;
}

private static immutable ubyte[256] alnumValue = buildAlnumTable();

/// Alphanumeric value of a byte, or -1 if it is not in the set.
int alphanumericValue(ubyte b) @safe pure nothrow @nogc
{
    const v = alnumValue[b];
    return v == 0xFF ? -1 : v;
}

/// Pick the most compact mode that can represent every byte of `text`.
Mode selectMode(const(ubyte)[] text) @safe pure nothrow @nogc
{
    bool numeric = true;
    foreach (b; text)
    {
        if (b < '0' || b > '9')
        {
            numeric = false;
            break;
        }
    }
    if (numeric)
        return Mode.numeric;
    foreach (b; text)
        if (alnumValue[b] == 0xFF)
            return Mode.byteMode;
    return Mode.alphanumeric;
}

/// The 4-bit mode indicator.
uint modeIndicator(Mode m) @safe pure nothrow @nogc
{
    final switch (m)
    {
    case Mode.numeric:
        return 1;
    case Mode.alphanumeric:
        return 2;
    case Mode.byteMode:
        return 4;
    }
}

/// Width in bits of the character count indicator.
int charCountBits(Mode m, int ver) @safe pure nothrow @nogc
{
    static immutable ubyte[3][3] widths = [
        [10, 12, 14], // numeric
        [9, 11, 13], // alphanumeric
        [8, 16, 16], // byte
    ];
    return widths[m][ver <= 9 ? 0 : ver <= 26 ? 1 : 2];
}

/// Number of data bits (excluding mode and count indicators) for `n` characters.
size_t dataBitLength(Mode m, size_t n) @safe pure nothrow @nogc
{
    final switch (m)
    {
    case Mode.numeric:
        static immutable ubyte[3] tail = [0, 4, 7];
        return 10 * (n / 3) + tail[n % 3];
    case Mode.alphanumeric:
        return 11 * (n / 2) + 6 * (n % 2);
    case Mode.byteMode:
        return 8 * n;
    }
}

/**
 * Smallest version in 1..40 whose data capacity at `ecl` holds `n`
 * characters of mode `m`, or -1 if none does.
 */
int selectVersion(Mode m, size_t n, Ecl ecl) @safe pure nothrow @nogc
{
    const bits = dataBitLength(m, n);
    foreach (ver; minVersion .. maxVersion + 1)
    {
        // A count that does not fit in its indicator cannot be encoded at this version.
        const cc = charCountBits(m, ver);
        if (n >= (size_t(1) << cc))
            continue;
        if (4 + cc + bits <= 8 * cast(size_t) dataCodewords(ver, ecl))
            return ver;
    }
    return -1;
}

/**
 * Pack `text` as one segment of mode `m` for a version-`ver` symbol and
 * apply the terminator and padding, returning exactly
 * `dataCodewords(ver, ecl)` bytes.
 */
ubyte[] packData(const(ubyte)[] text, Mode m, int ver, Ecl ecl) @safe pure nothrow
{
    const capacity = dataCodewords(ver, ecl);
    auto w = BitWriter(capacity);
    w.put(modeIndicator(m), 4);
    w.put(cast(uint) text.length, charCountBits(m, ver));
    final switch (m)
    {
    case Mode.numeric:
        size_t i = 0;
        for (; i + 3 <= text.length; i += 3)
            w.put((text[i] - '0') * 100 + (text[i + 1] - '0') * 10 + (text[i + 2] - '0'), 10);
        if (text.length - i == 2)
            w.put((text[i] - '0') * 10 + (text[i + 1] - '0'), 7);
        else if (text.length - i == 1)
            w.put(text[i] - '0', 4);
        break;
    case Mode.alphanumeric:
        size_t i = 0;
        for (; i + 2 <= text.length; i += 2)
            w.put(cast(uint)(45 * alnumValue[text[i]] + alnumValue[text[i + 1]]), 11);
        if (i < text.length)
            w.put(alnumValue[text[i]], 6);
        break;
    case Mode.byteMode:
        foreach (b; text)
            w.put(b, 8);
        break;
    }
    const total = 8 * cast(size_t) capacity;
    const rest = total - w.length;
    w.putZeros(rest < 4 ? rest : 4);
    w.alignToByte();
    w.padAlternating(0xEC, 0x11, capacity);
    return w.bytes;
}
