/**
 * Base64 (RFC 4648) encoding and strict decoding, written from scratch.
 *
 * Encoders: padded standard alphabet, unpadded URL-safe alphabet.
 *
 * The decoder accepts both alphabets (but never mixed in one string), padded
 * or unpadded; padding, when present, must be exactly what the encoder would
 * have produced. Non-zero trailing bits are ignored.
 */
module webhooks.base64;

import webhooks.buffer;

private immutable string standardAlphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
private immutable string urlSafeAlphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

private ubyte[256] makeDecodeTable() @safe pure nothrow @nogc
{
    ubyte[256] t;
    t[] = 0xFF;
    foreach (i; 0 .. 64)
    {
        t[standardAlphabet[i]] = cast(ubyte) i;
        t[urlSafeAlphabet[i]] = cast(ubyte) i;
    }
    return t;
}

private static immutable ubyte[256] decodeTable = makeDecodeTable();

private void encodeWith(ref OutBuffer output, Bytes data, string alphabet, bool pad)
    @safe pure nothrow
{
    output.reserve((data.length + 2) / 3 * 4);
    size_t i = 0;
    for (; i + 3 <= data.length; i += 3)
    {
        immutable n = data[i] << 16 | data[i + 1] << 8 | data[i + 2];
        output.put(cast(ubyte) alphabet[n >> 18 & 63]);
        output.put(cast(ubyte) alphabet[n >> 12 & 63]);
        output.put(cast(ubyte) alphabet[n >> 6 & 63]);
        output.put(cast(ubyte) alphabet[n & 63]);
    }
    immutable rest = data.length - i;
    if (rest == 1)
    {
        immutable n = data[i] << 16;
        output.put(cast(ubyte) alphabet[n >> 18 & 63]);
        output.put(cast(ubyte) alphabet[n >> 12 & 63]);
        if (pad)
            output.put("==");
    }
    else if (rest == 2)
    {
        immutable n = data[i] << 16 | data[i + 1] << 8;
        output.put(cast(ubyte) alphabet[n >> 18 & 63]);
        output.put(cast(ubyte) alphabet[n >> 12 & 63]);
        output.put(cast(ubyte) alphabet[n >> 6 & 63]);
        if (pad)
            output.put(cast(ubyte) '=');
    }
}

/// Append the padded standard-alphabet encoding of `data` to `output`.
void putStandard(ref OutBuffer output, Bytes data) @safe pure nothrow
{
    encodeWith(output, data, standardAlphabet, true);
}

/// Append the unpadded URL-safe encoding of `data` to `output`.
void putUrlSafe(ref OutBuffer output, Bytes data) @safe pure nothrow
{
    encodeWith(output, data, urlSafeAlphabet, false);
}

/// Padded standard Base64 of `data`.
string encodeStandard(Bytes data) @safe pure nothrow
{
    OutBuffer o;
    putStandard(o, data);
    return o.toString();
}

/// Unpadded URL-safe Base64 of `data`.
string encodeUrlSafe(Bytes data) @safe pure nothrow
{
    OutBuffer o;
    putUrlSafe(o, data);
    return o.toString();
}

/// Upper bound on the number of bytes `decodeInto` writes for `textLength` input characters.
size_t decodedCapacity(size_t textLength) @safe pure nothrow @nogc
{
    return textLength * 3 / 4;
}

/**
 * Decode `text` into the caller-provided buffer `dst`, which must hold at
 * least `decodedCapacity(text.length)` bytes.
 *
 * Returns: the number of bytes written, or -1 if `text` is not valid Base64.
 */
ptrdiff_t decodeInto(Bytes text, scope ubyte[] dst) @safe pure nothrow @nogc
{
    size_t bodyLen = text.length;
    while (bodyLen > 0 && text[bodyLen - 1] == '=')
        --bodyLen;
    immutable pad = text.length - bodyLen;
    immutable rem = bodyLen % 4;
    if (rem == 1)
        return -1;
    if (pad > 0)
    {
        // Padding must be exactly what the encoder would emit.
        if (rem == 0 || pad != 4 - rem)
            return -1;
    }
    assert(dst.length >= decodedCapacity(text.length));

    bool sawStandard = false, sawUrl = false;
    uint acc = 0;
    uint bits = 0;
    size_t o = 0;
    foreach (c; text[0 .. bodyLen])
    {
        immutable v = decodeTable[c];
        if (v == 0xFF)
            return -1;
        if (c == '+' || c == '/')
            sawStandard = true;
        else if (c == '-' || c == '_')
            sawUrl = true;
        acc = acc << 6 | v;
        bits += 6;
        if (bits >= 8)
        {
            bits -= 8;
            dst[o++] = cast(ubyte)(acc >> bits);
        }
    }
    if (sawStandard && sawUrl)
        return -1;
    return cast(ptrdiff_t) o;
}

/**
 * Decode `text` (either alphabet, padded or not).
 *
 * Params:
 *   text   = the Base64 characters
 *   result = receives the decoded bytes on success
 * Returns: `false` if `text` is not valid Base64 as described in the module header.
 */
bool decode(Bytes text, out ubyte[] result) @safe pure nothrow
{
    auto buf = new ubyte[decodedCapacity(text.length)];
    immutable n = decodeInto(text, buf);
    if (n < 0)
        return false;
    result = buf[0 .. n];
    return true;
}
