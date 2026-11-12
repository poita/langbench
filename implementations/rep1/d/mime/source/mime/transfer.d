/// Content-Transfer-Encoding decoders (quoted-printable and base64) and the
/// Adler-32 checksum used to fingerprint decoded content.
module mime.transfer;

import std.array : appender;

@safe:

private int hexValue(ubyte c) pure nothrow @nogc
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

/// Value of a hexadecimal digit, or -1.
int hexDigit(char c) pure nothrow @nogc { return hexValue(cast(ubyte) c); }

/// Decodes quoted-printable.  `=` + LF is a soft break, `=` + two hex digits
/// is a byte, a final lone `=` vanishes and any other `=` is literal.
/// Input lines are LF-terminated (CRLF already normalised).
ubyte[] decodeQuotedPrintable(const(ubyte)[] data) pure nothrow
{
    auto app = appender!(ubyte[])();
    app.reserve(data.length);
    size_t i = 0;
    const n = data.length;
    while (i < n)
    {
        const c = data[i];
        if (c != '=')
        {
            app.put(c);
            ++i;
            continue;
        }
        if (i + 1 < n && data[i + 1] == '\n')
            i += 2;
        else if (i + 2 < n && hexValue(data[i + 1]) >= 0 && hexValue(data[i + 2]) >= 0)
        {
            app.put(cast(ubyte)(hexValue(data[i + 1]) * 16 + hexValue(data[i + 2])));
            i += 3;
        }
        else if (i + 1 == n)
            ++i;
        else
        {
            app.put('=');
            ++i;
        }
    }
    return app.data;
}

private int base64Value(ubyte c) pure nothrow @nogc
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

/// Decodes base64, ignoring every byte outside the alphabet (padding
/// included).  A trailing partial group yields as many whole bytes as it has
/// bits for; a single leftover character is dropped.
ubyte[] decodeBase64(const(ubyte)[] data) pure nothrow
{
    auto app = appender!(ubyte[])();
    app.reserve(data.length / 4 * 3 + 3);
    uint acc = 0;
    int bits = 0;
    foreach (c; data)
    {
        const v = base64Value(c);
        if (v < 0)
            continue;
        acc = (acc << 6) | cast(uint) v;
        bits += 6;
        if (bits >= 8)
        {
            bits -= 8;
            app.put(cast(ubyte)((acc >> bits) & 0xFF));
            acc &= (1u << bits) - 1;
        }
    }
    return app.data;
}

/// `decode_body`: undoes the transfer encoding (`encoding` is lower-case).
/// Identity encodings and unknown ones return the input itself.
const(ubyte)[] decodeBody(const(ubyte)[] data, string encoding) pure nothrow
{
    switch (encoding)
    {
    case "quoted-printable":
        return decodeQuotedPrintable(data);
    case "base64":
        return decodeBase64(data);
    default:
        return data;
    }
}

/// Adler-32 of `data`.
uint adler32(const(ubyte)[] data) pure nothrow @nogc
{
    enum uint mod = 65521;
    uint a = 1, b = 0;
    foreach (x; data)
    {
        a += x;
        if (a >= mod) a -= mod;
        b += a;
        if (b >= mod) b -= mod;
    }
    return (b << 16) | a;
}

pure nothrow unittest
{
    static const(ubyte)[] u(string s) @trusted { return cast(const(ubyte)[]) s; }
    assert(decodeQuotedPrintable(u("a=20b")) == u("a b"));
    assert(decodeQuotedPrintable(u("a=\nb")) == u("ab"));
    assert(decodeQuotedPrintable(u("a=3Db")) == u("a=b"));
    assert(decodeQuotedPrintable(u("a=Zb")) == u("a=Zb"));
    assert(decodeQuotedPrintable(u("a=3\n")) == u("a=3\n"));
    assert(decodeQuotedPrintable(u("abc=")) == u("abc"));
    assert(decodeQuotedPrintable(u("=0D=0A")) == u("\r\n"));
    assert(decodeQuotedPrintable(u("x  \ny")) == u("x  \ny"));
    assert(decodeQuotedPrintable(u("=3")) == u("=3"));
}

pure nothrow unittest
{
    static const(ubyte)[] u(string s) @trusted { return cast(const(ubyte)[]) s; }
    assert(decodeBase64(u("AAECAw==")) == [0, 1, 2, 3]);
    assert(decodeBase64(u("TWE=")) == u("Ma"));
    assert(decodeBase64(u("TQ")) == u("M"));
    assert(decodeBase64(u("T")) == []);
    assert(decodeBase64(u("TW Fu\nTWFu")) == u("ManMan"));
    assert(decodeBody(u("x=41"), "7bit") == u("x=41"));
    assert(decodeBody(u("x=41"), "quoted-printable") == u("xA"));
    assert(adler32([]) == 1);
    assert(adler32(u("caf\xe9")) == 0x04680214);
    assert(adler32([0, 1, 2, 3]) == 0x000e0007);
}
