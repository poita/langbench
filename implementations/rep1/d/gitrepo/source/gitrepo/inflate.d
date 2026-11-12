/// zlib (RFC 1950) / DEFLATE (RFC 1951) decompression, implemented from scratch.
///
/// The decoder works on a complete in-memory input and reports how many input
/// bytes the DEFLATE stream occupied, so that back-to-back streams (as in a
/// packfile) can be found without knowing their compressed length.
module gitrepo.inflate;

import gitrepo.errors;

/// Thrown when a stream is not valid zlib/DEFLATE data.
class InflateError : GitError
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

private immutable ushort[29] lengthBase = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
    99, 115, 131, 163, 195, 227, 258
];
private immutable ubyte[29] lengthExtra = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
];
private immutable ushort[30] distBase = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
    1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
];
private immutable ubyte[30] distExtra = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
];
private immutable ubyte[19] clOrder = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
];

/// A canonical Huffman code, decoded one bit at a time.
private struct Huffman
{
    ushort[16] count; // number of codes of each length
    ushort[288] symbol; // symbols ordered by code
    int maxLen;

    /// Build from code lengths; throws on an over-subscribed or (for anything
    /// but a single one-bit code) incomplete set.
    void build(scope const(ubyte)[] lengths) @safe pure
    {
        count[] = 0;
        foreach (l; lengths)
            ++count[l];
        maxLen = 0;
        foreach_reverse (l; 1 .. 16)
            if (count[l])
            {
                maxLen = l;
                break;
            }
        int left = 1;
        foreach (l; 1 .. 16)
        {
            left <<= 1;
            left -= count[l];
            if (left < 0)
                throw new InflateError("over-subscribed Huffman code");
        }
        if (left > 0 && maxLen > 1)
            throw new InflateError("incomplete Huffman code");
        ushort[16] offs;
        foreach (l; 1 .. 15)
            offs[l + 1] = cast(ushort)(offs[l] + count[l]);
        foreach (sym, l; lengths)
            if (l)
                symbol[offs[l]++] = cast(ushort) sym;
    }
}

private struct Inflater
{
    const(ubyte)[] src;
    size_t pos;
    uint bitBuf;
    uint bitCnt;
    ubyte[] dst;
    size_t outLen;
    size_t limit;

    uint bits(uint n) @safe pure
    {
        while (bitCnt < n)
        {
            if (pos >= src.length)
                throw new InflateError("unexpected end of compressed data");
            bitBuf |= cast(uint) src[pos++] << bitCnt;
            bitCnt += 8;
        }
        immutable v = bitBuf & ((1u << n) - 1);
        bitBuf >>= n;
        bitCnt -= n;
        return v;
    }

    int decode(ref const Huffman h) @safe pure
    {
        int code, first, index;
        foreach (len; 1 .. h.maxLen + 1)
        {
            code |= cast(int) bits(1);
            immutable cnt = h.count[len];
            if (code - cnt < first)
                return h.symbol[index + (code - first)];
            index += cnt;
            first += cnt;
            first <<= 1;
            code <<= 1;
        }
        throw new InflateError("invalid Huffman code");
    }

    void reserve(size_t extra) @safe pure
    {
        immutable need = outLen + extra;
        if (need > limit)
            throw new InflateError("decompressed data too large");
        if (need > dst.length)
        {
            size_t cap = dst.length * 2;
            if (cap < need)
                cap = need;
            if (cap < 4096)
                cap = 4096;
            dst.length = cap;
        }
    }

    void stored() @safe pure
    {
        bitBuf = 0;
        bitCnt = 0;
        if (pos + 4 > src.length)
            throw new InflateError("unexpected end of compressed data");
        immutable len = src[pos] | (src[pos + 1] << 8);
        immutable nlen = src[pos + 2] | (src[pos + 3] << 8);
        pos += 4;
        if (len != (~nlen & 0xffff))
            throw new InflateError("stored block length check failed");
        if (pos + len > src.length)
            throw new InflateError("unexpected end of compressed data");
        reserve(len);
        dst[outLen .. outLen + len] = src[pos .. pos + len];
        outLen += len;
        pos += len;
    }

    void codes(ref const Huffman lit, ref const Huffman dist) @safe pure
    {
        while (true)
        {
            int sym = decode(lit);
            if (sym < 256)
            {
                reserve(1);
                dst[outLen++] = cast(ubyte) sym;
            }
            else if (sym == 256)
                return;
            else
            {
                sym -= 257;
                if (sym >= 29)
                    throw new InflateError("invalid length symbol");
                immutable len = lengthBase[sym] + bits(lengthExtra[sym]);
                immutable ds = decode(dist);
                if (ds >= 30)
                    throw new InflateError("invalid distance symbol");
                immutable d = distBase[ds] + bits(distExtra[ds]);
                if (d > outLen)
                    throw new InflateError("distance too far back");
                reserve(len);
                // Source and destination may overlap, so copy forwards.
                size_t from = outLen - d;
                foreach (i; 0 .. len)
                    dst[outLen + i] = dst[from + i];
                outLen += len;
            }
        }
    }

    void dynamic() @safe pure
    {
        immutable nlen = bits(5) + 257;
        immutable ndist = bits(5) + 1;
        immutable ncode = bits(4) + 4;
        if (nlen > 286 || ndist > 30)
            throw new InflateError("too many length or distance codes");
        ubyte[19] cl;
        foreach (i; 0 .. ncode)
            cl[clOrder[i]] = cast(ubyte) bits(3);
        Huffman clh;
        clh.build(cl[]);
        ubyte[320] lens;
        size_t idx;
        while (idx < nlen + ndist)
        {
            immutable sym = decode(clh);
            if (sym < 16)
                lens[idx++] = cast(ubyte) sym;
            else
            {
                ubyte prev = 0;
                uint rep;
                if (sym == 16)
                {
                    if (idx == 0)
                        throw new InflateError("repeat with no previous length");
                    prev = lens[idx - 1];
                    rep = 3 + bits(2);
                }
                else if (sym == 17)
                    rep = 3 + bits(3);
                else
                    rep = 11 + bits(7);
                if (idx + rep > nlen + ndist)
                    throw new InflateError("too many code lengths");
                lens[idx .. idx + rep] = prev;
                idx += rep;
            }
        }
        if (lens[256] == 0)
            throw new InflateError("no end-of-block code");
        Huffman lit, dist;
        lit.build(lens[0 .. nlen]);
        dist.build(lens[nlen .. nlen + ndist]);
        codes(lit, dist);
    }

    void run() @safe pure
    {
        bool last;
        do
        {
            last = bits(1) != 0;
            switch (bits(2))
            {
            case 0:
                stored();
                break;
            case 1:
                Huffman lit, dist;
                ubyte[288] l;
                l[0 .. 144] = 8;
                l[144 .. 256] = 9;
                l[256 .. 280] = 7;
                l[280 .. 288] = 8;
                lit.build(l[]);
                ubyte[32] d = 5;
                dist.build(d[]);
                codes(lit, dist);
                break;
            case 2:
                dynamic();
                break;
            default:
                throw new InflateError("invalid block type");
            }
        }
        while (!last);
    }
}

/// Decompress a raw DEFLATE stream (RFC 1951) starting at `src[0]`.
///
/// Params:
///   src      = the input; may continue past the end of the stream
///   consumed = set to the number of input bytes the stream occupied
///   sizeHint = expected output size, used to size the buffer (optional)
///   limit    = refuse to produce more than this many bytes
/// Throws: `InflateError` on malformed or truncated data.
ubyte[] inflateRaw(const(ubyte)[] src, out size_t consumed, size_t sizeHint = 0,
        size_t limit = size_t.max / 2) @safe pure
{
    Inflater s;
    s.src = src;
    s.limit = limit;
    s.dst = new ubyte[](sizeHint < limit ? sizeHint : limit);
    s.run();
    consumed = s.pos;
    s.dst.length = s.outLen;
    return s.dst;
}

/// Decompress a zlib stream (RFC 1950) starting at `src[0]`.
///
/// The two header bytes are validated (deflate method, header checksum, no
/// preset dictionary). The Adler-32 trailer is neither checked nor counted in
/// `consumed`; corrupt data is detected by the DEFLATE layer or by the caller's
/// own checks (object header, SHA-1).
ubyte[] zlibDecompress(const(ubyte)[] src, out size_t consumed, size_t sizeHint = 0,
        size_t limit = size_t.max / 2) @safe pure
{
    if (src.length < 2)
        throw new InflateError("truncated zlib header");
    immutable cmf = src[0], flg = src[1];
    if ((cmf & 0x0f) != 8 || ((cmf * 256 + flg) % 31) != 0 || (flg & 0x20) != 0)
        throw new InflateError("bad zlib header");
    size_t n;
    auto result = inflateRaw(src[2 .. $], n, sizeHint, limit);
    consumed = n + 2;
    return result;
}

/// ditto
ubyte[] zlibDecompress(const(ubyte)[] src) @safe pure
{
    size_t consumed;
    return zlibDecompress(src, consumed);
}

unittest
{
    // zlib.compress(b"hello hello hello hello\n", 9) -- fixed Huffman block.
    static immutable ubyte[] z = [
        0x78, 0xda, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0xc8, 0x40, 0x27, 0xb9, 0x00, 0x70,
        0xbe, 0x08, 0xbb
    ];
    size_t used;
    auto r = zlibDecompress(z, used);
    assert(cast(string) r == "hello hello hello hello\n");
    assert(used == z.length - 4);
}

unittest
{
    // A stored block (BFINAL=1, LEN=5), then trailing bytes of "another stream".
    static immutable ubyte[] z = [
        0x78, 0x01, 0x01, 0x05, 0x00, 0xfa, 0xff, 'a', 'b', 'c', 'd', 'e', 0, 0, 0, 0, 0xAA
    ];
    size_t used;
    auto r = zlibDecompress(z, used);
    assert(cast(string) r == "abcde");
    assert(used == 12);
}

unittest
{
    import std.exception : assertThrown;

    assertThrown!InflateError(zlibDecompress([0x78]));
    assertThrown!InflateError(zlibDecompress([0x78, 0x00])); // header checksum
    assertThrown!InflateError(zlibDecompress([0x79, 0x9c])); // not deflate? (0x79 & 15 == 9)
    assertThrown!InflateError(zlibDecompress([0x78, 0xbb])); // FDICT set
    assertThrown!InflateError(zlibDecompress([0x78, 0x9c, 0x07])); // block type 3
    assertThrown!InflateError(zlibDecompress([0x78, 0x9c, 0x01, 0x05, 0x00, 0xfa, 0xff, 'a'])); // truncated
    assertThrown!InflateError(zlibDecompress([0x78, 0x9c, 0x01, 0x05, 0x00, 0x00, 0x00])); // bad NLEN
}
