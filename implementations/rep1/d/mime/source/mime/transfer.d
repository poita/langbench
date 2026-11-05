/// Content-Transfer-Encoding decoders (`decode_body`), written by hand.
module mime.transfer;

import mime.ascii;

private static immutable byte[256] base64Table = () {
    byte[256] t;
    t[] = -1;
    foreach (i, c; "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        t[c] = cast(byte) i;
    return t;
}();

/// Decodes base64: every byte outside the alphabet (including `=`) is
/// skipped; a trailing group of two or three characters yields one or two
/// bytes, and a single leftover character is discarded.
ubyte[] decodeBase64(scope const(ubyte)[] s) @safe pure nothrow
{
    auto o = new ubyte[](3 * (s.length / 4) + 3 + 3);
    size_t n = 0;
    uint acc = 0;
    uint cnt = 0;
    foreach (c; s)
    {
        immutable v = base64Table[c];
        if (v < 0)
            continue;
        acc = (acc << 6) | v;
        if (++cnt == 4)
        {
            o[n++] = cast(ubyte)(acc >> 16);
            o[n++] = cast(ubyte)(acc >> 8);
            o[n++] = cast(ubyte) acc;
            acc = 0;
            cnt = 0;
        }
    }
    if (cnt == 2)
        o[n++] = cast(ubyte)(acc >> 4);
    else if (cnt == 3)
    {
        o[n++] = cast(ubyte)(acc >> 10);
        o[n++] = cast(ubyte)(acc >> 2);
    }
    return o[0 .. n];
}

/// Decodes quoted-printable. `=` + LF is a soft break, `=` + two hex digits
/// is a byte, a final `=` is dropped, any other `=` is literal. Everything
/// else, trailing blanks included, is copied unchanged.
ubyte[] decodeQuotedPrintable(scope const(ubyte)[] s) @safe pure nothrow
{
    auto o = new ubyte[](s.length);
    size_t n = 0;
    size_t i = 0;
    while (i < s.length)
    {
        // copy the run up to the next '='
        size_t j = i;
        while (j < s.length && s[j] != '=')
            j++;
        if (j > i)
        {
            o[n .. n + (j - i)] = s[i .. j];
            n += j - i;
            i = j;
        }
        if (i >= s.length)
            break;
        // s[i] == '='
        if (i + 1 < s.length && s[i + 1] == '\n')
            i += 2;
        else if (i + 2 < s.length && hexValue(cast(char) s[i + 1]) >= 0 && hexValue(cast(char) s[i + 2]) >= 0)
        {
            o[n++] = cast(ubyte)(hexValue(cast(char) s[i + 1]) * 16 + hexValue(cast(char) s[i + 2]));
            i += 3;
        }
        else if (i + 1 == s.length)
            i++;
        else
        {
            o[n++] = '=';
            i++;
        }
    }
    return o[0 .. n];
}

/// `decode_body(bytes, encoding)`: `encoding` is the lower-cased, stripped
/// Content-Transfer-Encoding token. Unknown encodings (and `7bit`, `8bit`,
/// `binary`) return the input slice itself without copying.
const(ubyte)[] decodeBody(const(ubyte)[] body_, string encoding) @safe pure nothrow
{
    switch (encoding)
    {
    case "base64":
        return decodeBase64(body_);
    case "quoted-printable":
        return decodeQuotedPrintable(body_);
    default:
        return body_;
    }
}
