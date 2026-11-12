/**
 * Base64 encoding and decoding, implemented from scratch.
 *
 * Encoding supports the standard alphabet (padded) and the URL-safe alphabet
 * (unpadded). Decoding is lenient about the alphabet — it accepts either, but
 * never a mixture — and strict about padding, as required for Standard
 * Webhooks secrets and signatures:
 *
 * $(UL
 *   $(LI padding, when present, must be exactly what the encoder would emit;)
 *   $(LI the unused low bits of the last character are ignored, so `QQ==`
 *        and `QR==` both decode to `0x41`;)
 *   $(LI whitespace and any other character make the input invalid.))
 */
module webhooks.base64;

private immutable string standardAlphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
private immutable string urlSafeAlphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

private string encodeWith(scope const(ubyte)[] data, string alphabet, bool pad) pure nothrow @safe
{
    auto result = new char[(data.length + 2) / 3 * 4];
    size_t o = 0;
    size_t i = 0;
    for (; i + 3 <= data.length; i += 3)
    {
        immutable v = (cast(uint) data[i] << 16) | (cast(uint) data[i + 1] << 8) | data[i + 2];
        result[o++] = alphabet[v >> 18];
        result[o++] = alphabet[(v >> 12) & 63];
        result[o++] = alphabet[(v >> 6) & 63];
        result[o++] = alphabet[v & 63];
    }
    immutable rest = data.length - i;
    if (rest == 1)
    {
        immutable v = cast(uint) data[i] << 16;
        result[o++] = alphabet[v >> 18];
        result[o++] = alphabet[(v >> 12) & 63];
        if (pad)
        {
            result[o++] = '=';
            result[o++] = '=';
        }
    }
    else if (rest == 2)
    {
        immutable v = (cast(uint) data[i] << 16) | (cast(uint) data[i + 1] << 8);
        result[o++] = alphabet[v >> 18];
        result[o++] = alphabet[(v >> 12) & 63];
        result[o++] = alphabet[(v >> 6) & 63];
        if (pad)
            result[o++] = '=';
    }
    return (() @trusted => cast(string) result[0 .. o])();
}

/// Standard-alphabet Base64 with `=` padding.
string encodeBase64(scope const(ubyte)[] data) pure nothrow @safe
{
    return encodeWith(data, standardAlphabet, true);
}

/// URL-safe-alphabet Base64 without padding.
string encodeBase64Url(scope const(ubyte)[] data) pure nothrow @safe
{
    return encodeWith(data, urlSafeAlphabet, false);
}

/// Appends the padded standard Base64 of `data` to `sink`.
void putBase64(Sink)(ref Sink sink, scope const(ubyte)[] data)
{
    sink.put(encodeBase64(data));
}

// Value of a base64 character: 0..63, or -1. `+/` and `-_` share the values
// 62 and 63; `kind` reports which alphabet-specific character was seen.
private int sextet(ubyte c, ref bool sawStandard, ref bool sawUrl) pure nothrow @safe @nogc
{
    if (c >= 'A' && c <= 'Z')
        return c - 'A';
    if (c >= 'a' && c <= 'z')
        return c - 'a' + 26;
    if (c >= '0' && c <= '9')
        return c - '0' + 52;
    switch (c)
    {
    case '+':
        sawStandard = true;
        return 62;
    case '/':
        sawStandard = true;
        return 63;
    case '-':
        sawUrl = true;
        return 62;
    case '_':
        sawUrl = true;
        return 63;
    default:
        return -1;
    }
}

/**
 * Decodes `input` (see the module description for the accepted forms).
 *
 * Params:
 *   input = the Base64 text, as bytes
 *   result = receives the decoded bytes on success
 * Returns: `true` if `input` is valid Base64, `false` otherwise.
 */
bool decodeBase64(scope const(ubyte)[] input, out ubyte[] result) pure nothrow @safe
{
    size_t bodyLength = input.length;
    while (bodyLength > 0 && input[bodyLength - 1] == '=')
        --bodyLength;
    immutable padding = input.length - bodyLength;
    immutable rem = bodyLength % 4;
    if (rem == 1 || padding > 2)
        return false;
    if (padding > 0)
    {
        if (rem == 0 || (rem == 3 && padding != 1) || (rem == 2 && padding != 2))
            return false;
    }

    bool sawStandard = false;
    bool sawUrl = false;
    auto bytes = new ubyte[bodyLength * 6 / 8];
    uint acc = 0;
    uint bits = 0;
    size_t o = 0;
    foreach (c; input[0 .. bodyLength])
    {
        immutable v = sextet(c, sawStandard, sawUrl);
        if (v < 0)
            return false;
        acc = (acc << 6) | cast(uint) v;
        bits += 6;
        if (bits >= 8)
        {
            bits -= 8;
            bytes[o++] = cast(ubyte)(acc >> bits);
            acc &= (1u << bits) - 1;
        }
    }
    if (sawStandard && sawUrl)
        return false;
    assert(o == bytes.length);
    result = bytes;
    return true;
}

/// ditto
bool decodeBase64(scope const(char)[] input, out ubyte[] result) pure nothrow @trusted
{
    return decodeBase64(cast(const(ubyte)[]) input, result);
}

@safe unittest
{
    assert(encodeBase64([]) == "");
    assert(encodeBase64(cast(const(ubyte)[]) "f") == "Zg==");
    assert(encodeBase64(cast(const(ubyte)[]) "fo") == "Zm8=");
    assert(encodeBase64(cast(const(ubyte)[]) "foo") == "Zm9v");
    assert(encodeBase64(cast(const(ubyte)[]) "foobar") == "Zm9vYmFy");
    assert(encodeBase64([0xfb, 0xff]) == "+/8=");
    assert(encodeBase64Url([0xfb, 0xff]) == "-_8");
    assert(encodeBase64Url(cast(const(ubyte)[]) "f") == "Zg");
    assert(encodeBase64Url([]) == "");
}

@safe unittest
{
    ubyte[] r;
    assert(decodeBase64("", r) && r.length == 0);
    assert(decodeBase64("Zm9v", r) && r == cast(const(ubyte)[]) "foo");
    assert(decodeBase64("Zg==", r) && r == cast(const(ubyte)[]) "f");
    assert(decodeBase64("Zg", r) && r == cast(const(ubyte)[]) "f");
    assert(decodeBase64("+/8=", r) && r == [0xfb, 0xff]);
    assert(decodeBase64("-_8", r) && r == [0xfb, 0xff]);
    // Leftover bits are not checked.
    assert(decodeBase64("QQ==", r) && r == [0x41]);
    assert(decodeBase64("QR==", r) && r == [0x41]);
}

@safe unittest
{
    ubyte[] r;
    assert(!decodeBase64("Z", r)); // length mod 4 == 1
    assert(!decodeBase64("Zg=", r)); // wrong padding amount
    assert(!decodeBase64("Zm8==", r));
    assert(!decodeBase64("Zm9v=", r)); // nothing to pad
    assert(!decodeBase64("====", r));
    assert(!decodeBase64("Zg===", r)); // p > 2
    assert(!decodeBase64("Z=g=", r)); // '=' in the middle
    assert(!decodeBase64("+-8=", r)); // mixed alphabets
    assert(!decodeBase64("-/8", r));
    assert(!decodeBase64("Zm 9v", r)); // whitespace
    assert(!decodeBase64("Zm9v\n", r));
    assert(!decodeBase64("Zm9é", r));
}

@safe unittest
{
    // Round trip on every length mod 3, in both alphabets.
    ubyte[] data;
    foreach (n; 0 .. 70)
    {
        ubyte[] r;
        assert(decodeBase64(encodeBase64(data), r) && r == data);
        assert(decodeBase64(encodeBase64Url(data), r) && r == data);
        data ~= cast(ubyte)(n * 37 + 250);
    }
}
