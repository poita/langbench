/**
 * Base64 encoding and decoding, implemented from scratch.
 *
 * Encoding comes in two flavours (padded standard, unpadded URL-safe).
 * Decoding is a single lenient-alphabet routine: it accepts either alphabet
 * (but not a mix), optional exact padding, and ignores unused trailing bits.
 */
module webhooks.base64;

import webhooks.outbuf;

private immutable string standardAlphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
private immutable string urlAlphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

// Decode table entry: low byte = 6-bit value, high byte = class flags.
// 0 means "not a Base64 character".
private enum ushort commonFlag = 0x100; // in both alphabets
private enum ushort standardFlag = 0x200; // only in the standard alphabet (+ /)
private enum ushort urlFlag = 0x400; // only in the URL-safe alphabet (- _)

private immutable ushort[256] decodeTable = () {
    ushort[256] t;
    foreach (i; 0 .. 62)
        t[standardAlphabet[i]] = cast(ushort)(i | commonFlag);
    t['+'] = 62 | standardFlag;
    t['/'] = 63 | standardFlag;
    t['-'] = 62 | urlFlag;
    t['_'] = 63 | urlFlag;
    return t;
}();

private void encodeWith(ref OutBuf output, scope const(ubyte)[] data, string alphabet, bool pad)
    @safe pure nothrow
{
    immutable full = data.length / 3;
    immutable rest = data.length % 3;
    immutable outLen = full * 4 + (rest == 0 ? 0 : (pad ? 4 : rest + 1));
    auto dst = output.extend(outLen);
    size_t o = 0;
    foreach (g; 0 .. full)
    {
        immutable n = (cast(uint) data[3 * g] << 16) | (cast(uint) data[3 * g + 1] << 8)
            | cast(uint) data[3 * g + 2];
        dst[o++] = alphabet[(n >> 18) & 63];
        dst[o++] = alphabet[(n >> 12) & 63];
        dst[o++] = alphabet[(n >> 6) & 63];
        dst[o++] = alphabet[n & 63];
    }
    if (rest == 1)
    {
        immutable n = cast(uint) data[3 * full] << 16;
        dst[o++] = alphabet[(n >> 18) & 63];
        dst[o++] = alphabet[(n >> 12) & 63];
        if (pad)
        {
            dst[o++] = '=';
            dst[o++] = '=';
        }
    }
    else if (rest == 2)
    {
        immutable n = (cast(uint) data[3 * full] << 16) | (cast(uint) data[3 * full + 1] << 8);
        dst[o++] = alphabet[(n >> 18) & 63];
        dst[o++] = alphabet[(n >> 12) & 63];
        dst[o++] = alphabet[(n >> 6) & 63];
        if (pad)
            dst[o++] = '=';
    }
    assert(o == outLen);
}

/// Appends the padded standard-alphabet encoding of `data` to `output`.
void appendEncoded(ref OutBuf output, scope const(ubyte)[] data) @safe pure nothrow
{
    encodeWith(output, data, standardAlphabet, true);
}

/// Appends the unpadded URL-safe encoding of `data` to `output`.
void appendEncodedUrl(ref OutBuf output, scope const(ubyte)[] data) @safe pure nothrow
{
    encodeWith(output, data, urlAlphabet, false);
}

/// Padded standard Base64 of `data`.
string encode(scope const(ubyte)[] data) @trusted pure nothrow
{
    OutBuf o;
    appendEncoded(o, data);
    return cast(string) o.data.idup;
}

/// Unpadded URL-safe Base64 of `data`.
string encodeUrl(scope const(ubyte)[] data) @trusted pure nothrow
{
    OutBuf o;
    appendEncodedUrl(o, data);
    return cast(string) o.data.idup;
}

/**
 * Decodes `text` into `dst`, validating as it goes.
 *
 * `dst` must have room for `text.length * 3 / 4` bytes.
 *
 * Returns: the number of bytes written, or -1 if `text` is not valid Base64
 * (stray or misplaced `=`, a character outside both alphabets, both alphabets
 * mixed, impossible length, or padding that is not exactly what an encoder
 * would emit). Unused trailing bits are not checked.
 */
ptrdiff_t decodeInto(scope const(ubyte)[] text, scope ubyte[] dst) @safe pure nothrow @nogc
{
    size_t padCount = 0;
    while (padCount < text.length && text[$ - 1 - padCount] == '=')
        padCount++;
    auto body_ = text[0 .. $ - padCount];
    immutable n = body_.length;
    immutable rem = n & 3;
    if (rem == 1 || padCount > 2)
        return -1;
    if (padCount > 0 && (rem == 0 || padCount != 4 - rem))
        return -1;

    immutable outLen = n * 6 / 8;
    assert(dst.length >= outLen);

    uint flags = 0;
    uint acc = 0;
    uint bits = 0;
    size_t o = 0;
    foreach (c; body_)
    {
        immutable e = decodeTable[c];
        if (e == 0)
            return -1;
        flags |= e;
        acc = (acc << 6) | (e & 0x3f);
        bits += 6;
        if (bits >= 8)
        {
            bits -= 8;
            dst[o++] = cast(ubyte)(acc >> bits);
        }
    }
    if ((flags & standardFlag) && (flags & urlFlag))
        return -1;
    assert(o == outLen);
    return o;
}

/**
 * Decodes `text` (either alphabet, optional exact padding).
 *
 * Params:
 *   text = the Base64 text
 *   bytes = receives the decoded bytes (empty on failure)
 * Returns: `false` if `text` is invalid.
 */
bool decode(scope const(ubyte)[] text, out ubyte[] bytes) @safe pure nothrow
{
    auto buf = new ubyte[text.length * 3 / 4];
    immutable n = decodeInto(text, buf);
    if (n < 0)
        return false;
    bytes = buf[0 .. n];
    return true;
}
