/// zlib (RFC 1950) / DEFLATE (RFC 1951) decompression, implemented from scratch.
///
/// The decoder uses a 64-bit LSB-first bit buffer and two-level Huffman lookup
/// tables (10 root bits for literal/length codes, 8 for distance codes) kept in
/// reusable buffers. The Adler-32 trailer is not checked.
module gitrepo.inflate;

import gitrepo.errors;

/// Raised for malformed zlib/DEFLATE data.
class InflateError : GitError
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

private immutable ushort[29] lengthBase = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
    131, 163, 195, 227, 258
];
private immutable ubyte[29] lengthExtra = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
];
private immutable ushort[30] distBase = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
];
private immutable ubyte[30] distExtra = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
];
private immutable ubyte[19] clOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

/// Capacity hints larger than this are ignored; the output still grows on demand.
enum size_t maxInitialCapacity = 64 << 20;

// A table entry is 0 (not a code), a leaf `(symbol << 8) | codeLength`, or a
// pointer `(subtableOffset << 8) | 0x80 | subtableBits` into the same array.
private struct HuffTable
{
    uint[] entries;
    uint rootBits;

    void build(scope const(ubyte)[] lengths, uint root) @safe
    {
        rootBits = root;
        uint[16] count;
        foreach (l; lengths)
            count[l]++;
        count[0] = 0;
        int left = 1;
        uint maxLen = 0;
        foreach (len; 1 .. 16)
        {
            left <<= 1;
            left -= count[len];
            if (left < 0)
                throw new InflateError("over-subscribed Huffman code");
            if (count[len])
                maxLen = len;
        }
        uint[16] next;
        uint code = 0;
        foreach (len; 1 .. 16)
        {
            code = (code + count[len - 1]) << 1;
            next[len] = code;
        }
        ushort[320] rev;
        foreach (sym, l; lengths)
        {
            if (l == 0)
                continue;
            uint c = next[l]++;
            uint r = 0;
            foreach (_; 0 .. l)
            {
                r = (r << 1) | (c & 1);
                c >>= 1;
            }
            rev[sym] = cast(ushort) r;
        }

        immutable rootSize = 1u << root;
        immutable rootMask = rootSize - 1;
        size_t total = rootSize;
        if (maxLen > root)
        {
            ubyte[1024] subBits;
            subBits[0 .. rootSize] = 0;
            foreach (sym, l; lengths)
            {
                if (l > root)
                {
                    immutable p = rev[sym] & rootMask;
                    if (l - root > subBits[p])
                        subBits[p] = cast(ubyte)(l - root);
                }
            }
            foreach (p; 0 .. rootSize)
                if (subBits[p])
                    total += 1u << subBits[p];
            if (entries.length < total)
                entries.length = total;
            entries[0 .. total] = 0;
            size_t off = rootSize;
            foreach (p; 0 .. rootSize)
            {
                if (subBits[p])
                {
                    entries[p] = cast(uint)(off << 8) | 0x80 | subBits[p];
                    off += 1u << subBits[p];
                }
            }
        }
        else
        {
            if (entries.length < total)
                entries.length = total;
            entries[0 .. total] = 0;
        }
        foreach (sym, l; lengths)
        {
            if (l == 0)
                continue;
            immutable e = cast(uint)(sym << 8) | l;
            if (l <= root)
            {
                for (size_t i = rev[sym]; i < rootSize; i += 1u << l)
                    entries[i] = e;
            }
            else
            {
                immutable ptr = entries[rev[sym] & rootMask];
                immutable off = ptr >> 8;
                immutable sb = ptr & 15;
                for (size_t i = rev[sym] >> root; i < (1u << sb); i += 1u << (l - root))
                    entries[off + i] = e;
            }
        }
    }

    /// Returns the leaf entry for the next bits (0 if not a code).
    uint lookup(ulong bits) const @safe pure nothrow @nogc
    {
        uint e = entries[cast(size_t)(bits & ((1u << rootBits) - 1))];
        if (e & 0x80)
            e = entries[(e >> 8) + cast(size_t)((bits >> rootBits) & ((1u << (e & 15)) - 1))];
        return e;
    }
}

/// A reusable zlib decompressor. Not thread safe; keep one per thread.
final class Inflater
{
    private HuffTable litTable, distTable, clTable, fixedLit, fixedDist;
    private bool fixedBuilt;

    private const(ubyte)[] src;
    private size_t pos;
    private ulong bb;
    private uint bc;
    private ubyte[] dst;
    private size_t dstLen;

    /// Decompress the zlib stream that starts at `data[0]`. Bytes after the end of
    /// the DEFLATE stream are ignored. `sizeHint` is only the initial capacity.
    /// Returns a freshly allocated array.
    ubyte[] decompress(const(ubyte)[] data, size_t sizeHint = 0) @trusted
    {
        if (data.length < 2)
            throw new InflateError("truncated zlib header");
        immutable cmf = data[0], flg = data[1];
        if ((cmf & 15) != 8 || ((cmf << 8) | flg) % 31 != 0 || (flg & 0x20) != 0)
            throw new InflateError("bad zlib header");
        src = data;
        pos = 2;
        bb = 0;
        bc = 0;
        dstLen = 0;
        dst = new ubyte[sizeHint < maxInitialCapacity ? sizeHint : maxInitialCapacity];
        scope (exit)
        {
            src = null;
            dst = null;
        }
        decodeBlocks();
        return dst[0 .. dstLen];
    }

    private void refill() @safe pure nothrow @nogc
    {
        while (bc <= 56 && pos < src.length)
        {
            bb |= cast(ulong) src[pos++] << bc;
            bc += 8;
        }
    }

    private void grow(size_t need) @safe pure
    {
        size_t cap = dst.length * 2;
        if (cap < dstLen + need)
            cap = dstLen + need;
        if (cap < 256)
            cap = 256;
        if (cap > (size_t(1) << 31))
            throw new InflateError("output too large");
        dst.length = cap;
    }

    private void decodeBlocks() @trusted
    {
        bool last;
        do
        {
            refill();
            if (bc < 3)
                throw new InflateError("unexpected end of data");
            last = (bb & 1) != 0;
            immutable type = cast(uint)(bb >> 1) & 3;
            bb >>= 3;
            bc -= 3;
            final switch (type)
            {
            case 0:
                stored();
                break;
            case 1:
                if (!fixedBuilt)
                    buildFixed();
                codes(fixedLit, fixedDist);
                break;
            case 2:
                readDynamic();
                codes(litTable, distTable);
                break;
            case 3:
                throw new InflateError("bad block type");
            }
        }
        while (!last);
    }

    private void buildFixed() @safe
    {
        ubyte[288] l;
        l[0 .. 144] = 8;
        l[144 .. 256] = 9;
        l[256 .. 280] = 7;
        l[280 .. 288] = 8;
        fixedLit.build(l[], 10);
        ubyte[32] d = 5;
        fixedDist.build(d[], 8);
        fixedBuilt = true;
    }

    private void stored() @trusted
    {
        immutable drop = bc & 7;
        bb >>= drop;
        bc -= drop;
        refill();
        if (bc < 32)
            throw new InflateError("unexpected end of data");
        immutable len = cast(uint)(bb & 0xffff);
        immutable nlen = cast(uint)((bb >> 16) & 0xffff);
        if ((len ^ 0xffff) != nlen)
            throw new InflateError("stored block length mismatch");
        bb >>= 32;
        bc -= 32;
        // Whole bytes still in the bit buffer were read ahead; give them back.
        pos -= bc / 8;
        bb = 0;
        bc = 0;
        if (src.length - pos < len)
            throw new InflateError("truncated stored block");
        if (dstLen + len > dst.length)
            grow(len);
        dst[dstLen .. dstLen + len] = src[pos .. pos + len];
        dstLen += len;
        pos += len;
    }

    private void readDynamic() @trusted
    {
        refill();
        if (bc < 14)
            throw new InflateError("unexpected end of data");
        immutable hlit = cast(uint)(bb & 31) + 257;
        immutable hdist = cast(uint)((bb >> 5) & 31) + 1;
        immutable hclen = cast(uint)((bb >> 10) & 15) + 4;
        bb >>= 14;
        bc -= 14;
        if (hlit > 286 || hdist > 30)
            throw new InflateError("bad code counts");
        ubyte[19] cl;
        foreach (i; 0 .. hclen)
        {
            refill();
            if (bc < 3)
                throw new InflateError("unexpected end of data");
            cl[clOrder[i]] = cast(ubyte)(bb & 7);
            bb >>= 3;
            bc -= 3;
        }
        clTable.build(cl[], 7);
        ubyte[320] lens;
        immutable total = hlit + hdist;
        uint i = 0;
        while (i < total)
        {
            refill();
            immutable e = clTable.lookup(bb);
            immutable len = e & 0x7f;
            if (e == 0 || len > bc)
                throw new InflateError("bad code length code");
            bb >>= len;
            bc -= len;
            immutable sym = e >> 8;
            if (sym < 16)
            {
                lens[i++] = cast(ubyte) sym;
                continue;
            }
            uint rep;
            ubyte val = 0;
            uint extra;
            if (sym == 16)
            {
                if (i == 0)
                    throw new InflateError("repeat with no previous length");
                val = lens[i - 1];
                extra = 2;
            }
            else
                extra = sym == 17 ? 3 : 7;
            if (bc < extra)
                throw new InflateError("unexpected end of data");
            rep = cast(uint)(bb & ((1u << extra) - 1)) + (sym == 16 ? 3 : sym == 17 ? 3 : 11);
            bb >>= extra;
            bc -= extra;
            if (i + rep > total)
                throw new InflateError("code lengths overflow");
            lens[i .. i + rep] = val;
            i += rep;
        }
        if (lens[256] == 0)
            throw new InflateError("missing end-of-block code");
        litTable.build(lens[0 .. hlit], 10);
        distTable.build(lens[hlit .. total], 8);
    }

    private void codes(ref HuffTable lit, ref HuffTable dist) @trusted
    {
        ulong bb = this.bb;
        uint bc = this.bc;
        size_t pos = this.pos;
        size_t dstLen = this.dstLen;
        immutable srcLen = src.length;
        for (;;)
        {
            while (bc <= 56 && pos < srcLen)
            {
                bb |= cast(ulong) src[pos++] << bc;
                bc += 8;
            }
            uint e = lit.lookup(bb);
            uint len = e & 0x7f;
            if (e == 0 || len > bc)
                throw new InflateError("bad literal/length code");
            bb >>= len;
            bc -= len;
            immutable sym = e >> 8;
            if (sym < 256)
            {
                if (dstLen == dst.length)
                {
                    this.dstLen = dstLen;
                    grow(1);
                }
                dst[dstLen++] = cast(ubyte) sym;
                continue;
            }
            if (sym == 256)
                break;
            if (sym > 285)
                throw new InflateError("bad length symbol");
            immutable li = sym - 257;
            immutable lextra = lengthExtra[li];
            if (lextra > bc)
                throw new InflateError("unexpected end of data");
            immutable length = lengthBase[li] + cast(uint)(bb & ((1u << lextra) - 1));
            bb >>= lextra;
            bc -= lextra;
            e = dist.lookup(bb);
            len = e & 0x7f;
            if (e == 0 || len > bc)
                throw new InflateError("bad distance code");
            bb >>= len;
            bc -= len;
            immutable ds = e >> 8;
            if (ds >= 30)
                throw new InflateError("bad distance symbol");
            immutable dextra = distExtra[ds];
            if (dextra > bc)
                throw new InflateError("unexpected end of data");
            immutable distance = distBase[ds] + cast(uint)(bb & ((1u << dextra) - 1));
            bb >>= dextra;
            bc -= dextra;
            if (distance > dstLen)
                throw new InflateError("distance too far back");
            if (dstLen + length > dst.length)
            {
                this.dstLen = dstLen;
                grow(length);
            }
            if (distance >= length)
                dst[dstLen .. dstLen + length] = dst[dstLen - distance .. dstLen - distance + length];
            else
            {
                foreach (k; 0 .. length)
                    dst[dstLen + k] = dst[dstLen + k - distance];
            }
            dstLen += length;
        }
        this.bb = bb;
        this.bc = bc;
        this.pos = pos;
        this.dstLen = dstLen;
    }
}
