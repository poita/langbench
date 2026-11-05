/**
 * Base64 (standard padded, URL-safe unpadded) and the strict-ish decoder
 * defined by the Standard Webhooks simulator spec.
 */
module webhooks.base64;

import webhooks.buffer;

private immutable string standardAlphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
private immutable string urlAlphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

private enum ubyte invalid = 0xff;
private enum ubyte standardOnly = 0x40; // '+' and '/'
private enum ubyte urlOnly = 0x80;      // '-' and '_'

private immutable ubyte[256] decodeTable = () {
    ubyte[256] t;
    t[] = invalid;
    foreach (i, c; standardAlphabet)
        t[c] = cast(ubyte) i;
    t['+'] |= standardOnly;
    t['/'] |= standardOnly;
    t['-'] = cast(ubyte)(62 | urlOnly);
    t['_'] = cast(ubyte)(63 | urlOnly);
    return t;
}();

private void encodeWith(scope const(ubyte)[] data, string alphabet, bool pad, ref ByteSink sink)
    @safe pure nothrow
{
    sink.reserve((data.length + 2) / 3 * 4);
    size_t i = 0;
    for (; i + 3 <= data.length; i += 3)
    {
        immutable v = (cast(uint) data[i] << 16) | (cast(uint) data[i + 1] << 8) | data[i + 2];
        sink.put(cast(ubyte) alphabet[v >> 18]);
        sink.put(cast(ubyte) alphabet[(v >> 12) & 63]);
        sink.put(cast(ubyte) alphabet[(v >> 6) & 63]);
        sink.put(cast(ubyte) alphabet[v & 63]);
    }
    immutable rest = data.length - i;
    if (rest == 1)
    {
        immutable v = cast(uint) data[i] << 16;
        sink.put(cast(ubyte) alphabet[v >> 18]);
        sink.put(cast(ubyte) alphabet[(v >> 12) & 63]);
        if (pad)
            sink.put("==");
    }
    else if (rest == 2)
    {
        immutable v = (cast(uint) data[i] << 16) | (cast(uint) data[i + 1] << 8);
        sink.put(cast(ubyte) alphabet[v >> 18]);
        sink.put(cast(ubyte) alphabet[(v >> 12) & 63]);
        sink.put(cast(ubyte) alphabet[(v >> 6) & 63]);
        if (pad)
            sink.putChar('=');
    }
}

/// Appends padded standard Base64 of `data` to `sink`.
void encodeStandard(scope const(ubyte)[] data, ref ByteSink sink) @safe pure nothrow
{
    encodeWith(data, standardAlphabet, true, sink);
}

/// Appends unpadded URL-safe Base64 of `data` to `sink`.
void encodeUrlSafe(scope const(ubyte)[] data, ref ByteSink sink) @safe pure nothrow
{
    encodeWith(data, urlAlphabet, false, sink);
}

/// Padded standard Base64 as a string.
string encodeStandard(scope const(ubyte)[] data) @trusted pure nothrow
{
    ByteSink s;
    encodeStandard(data, s);
    return cast(string) s.data.idup;
}

/// Unpadded URL-safe Base64 as a string.
string encodeUrlSafe(scope const(ubyte)[] data) @trusted pure nothrow
{
    ByteSink s;
    encodeUrlSafe(data, s);
    return cast(string) s.data.idup;
}

/// Upper bound on the decoded size of `textLength` Base64 characters.
size_t maxDecodedLength(size_t textLength) @safe pure nothrow @nogc
{
    return textLength / 4 * 3 + 3;
}

/**
 * Decodes `text` into `dst` (which must hold at least
 * `maxDecodedLength(text.length)` bytes).
 *
 * Rules: either alphabet but not both; optional padding that must be exactly
 * what the encoder would emit; length mod 4 == 1 invalid; unused trailing
 * bits are ignored.
 *
 * Returns: the number of bytes written, or -1 if `text` is invalid.
 */
ptrdiff_t decodeInto(scope const(ubyte)[] text, scope ubyte[] dst) @safe pure nothrow @nogc
{
    size_t n = text.length;
    while (n > 0 && text[n - 1] == '=')
        --n;
    immutable p = text.length - n;
    immutable rem = n % 4;
    if (rem == 1 || p > 2)
        return -1;
    if (p > 0)
    {
        if (rem == 0)
            return -1;
        if (p != 4 - rem)
            return -1;
    }
    uint acc = 0;
    uint bits = 0;
    size_t out_ = 0;
    ubyte seen = 0;
    foreach (c; text[0 .. n])
    {
        immutable v = decodeTable[c];
        if (v == invalid)
            return -1;
        seen |= v & (standardOnly | urlOnly);
        acc = (acc << 6) | (v & 63);
        bits += 6;
        if (bits >= 8)
        {
            bits -= 8;
            dst[out_++] = cast(ubyte)(acc >> bits);
            acc &= (1u << bits) - 1;
        }
    }
    if (seen == (standardOnly | urlOnly))
        return -1;
    return cast(ptrdiff_t) out_;
}

/// Decodes `text` into a freshly allocated buffer. Returns false if invalid.
bool decode(scope const(ubyte)[] text, out ubyte[] bytes) @safe pure nothrow
{
    auto buf = new ubyte[maxDecodedLength(text.length)];
    immutable n = decodeInto(text, buf);
    if (n < 0)
        return false;
    bytes = buf[0 .. n];
    return true;
}

/// Overload for string input.
bool decode(scope const(char)[] text, out ubyte[] bytes) @trusted pure nothrow
{
    return decode(cast(const(ubyte)[]) text, bytes);
}
