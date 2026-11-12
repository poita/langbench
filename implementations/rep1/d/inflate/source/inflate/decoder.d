/**
 * The DEFLATE decoder (RFC 1951).
 *
 * Decoding is a single pass over the input with table-driven Huffman
 * decoding (see `inflate.huffman`). Back-references copy from the output
 * already produced, so the whole output is held in memory.
 */
module inflate.decoder;

import inflate.bitreader : BitReader;
import inflate.constants : codeLengthOrder, distBase, distExtra, endOfBlock, fixedDistLengths,
    fixedLitLenLengths, lengthBase, lengthExtra, maxDistSymbol, maxLitLenSymbol;
import inflate.error : fail, InflateError, InflateException;
import inflate.huffman : CodePolicy, HuffmanTable;

/**
 * Decompress a raw DEFLATE stream.
 *
 * Params:
 *     data      = the compressed stream (no zlib/gzip wrapper)
 *     maxOutput = fail with `InflateError.outputLimitExceeded` rather than
 *                 produce more than this many bytes
 * Returns: the decompressed bytes
 * Throws: `InflateException` if the stream is malformed, truncated, or has
 *         whole bytes after the final block.
 */
ubyte[] decompress(scope const(ubyte)[] data, size_t maxOutput = size_t.max) @safe pure
{
    auto d = Decoder(data, maxOutput);
    return d.run();
}

/**
 * Like `decompress`, but returns `false` instead of throwing when the stream is
 * malformed. `result` is only meaningful when `true` is returned.
 */
bool tryDecompress(scope const(ubyte)[] data, out ubyte[] result, size_t maxOutput = size_t.max) @safe pure
{
    try
    {
        result = decompress(data, maxOutput);
        return true;
    }
    catch (InflateException)
    {
        return false;
    }
}

private struct Decoder
{
    BitReader br;
    size_t maxOutput;
    ubyte[] outBuf;
    size_t outLen;
    HuffmanTable litTable, distTable, clTable;
    bool fixedReady;
    HuffmanTable fixedLit, fixedDist;

    this(const(ubyte)[] data, size_t maxOutput) @safe pure
    {
        br = BitReader(data);
        this.maxOutput = maxOutput;
        litTable = HuffmanTable(10, 288);
        distTable = HuffmanTable(8, 32);
        clTable = HuffmanTable(7, 19);
        outBuf = new ubyte[data.length < (size_t.max >> 4) ? data.length * 4 + 4096 : 4096];
    }

    ubyte[] run() @safe pure
    {
        bool last;
        do
        {
            br.refill();
            last = br.bits(1) != 0;
            switch (br.bits(2))
            {
            case 0:
                storedBlock();
                break;
            case 1:
                if (!fixedReady)
                {
                    fixedLit = HuffmanTable(9, 288);
                    fixedLit.build(fixedLitLenLengths[], CodePolicy.complete);
                    fixedDist = HuffmanTable(5, 32);
                    fixedDist.build(fixedDistLengths[], CodePolicy.complete);
                    fixedReady = true;
                }
                codedBlock(fixedLit, fixedDist);
                break;
            case 2:
                dynamicTables();
                codedBlock(litTable, distTable);
                break;
            default:
                fail(InflateError.invalidBlockType, "invalid block type 3");
            }
        }
        while (!last);

        if (br.hasUnconsumedBytes)
            fail(InflateError.trailingData, "data after the final block");
        if (outLen > maxOutput)
            fail(InflateError.outputLimitExceeded, "output limit exceeded");
        return outBuf[0 .. outLen];
    }

    /// Make room for `extra` more output bytes.
    void reserve(size_t extra) @safe pure
    {
        if (outLen > maxOutput || extra > maxOutput - outLen)
            fail(InflateError.outputLimitExceeded, "output limit exceeded");
        const need = outLen + extra;
        if (need > outBuf.length)
        {
            size_t cap = outBuf.length * 2;
            if (cap < need)
                cap = need;
            outBuf.length = cap;
        }
    }

    void storedBlock() @safe pure
    {
        br.alignToByte();
        br.refill();
        const len = br.bits(16);
        const nlen = br.bits(16);
        if ((len ^ nlen) != 0xffff)
            fail(InflateError.storedLengthMismatch, "stored block LEN/NLEN mismatch");
        const src = br.takeBytes(len);
        reserve(len);
        outBuf[outLen .. outLen + len] = src[];
        outLen += len;
    }

    void dynamicTables() @safe pure
    {
        const hlit = br.readBits(5);
        const hdist = br.readBits(5);
        const hclen = br.readBits(4);
        if (hlit > 29 || hdist > 29)
            fail(InflateError.tooManyCodes, "too many length or distance codes");

        ubyte[19] clLens;
        foreach (i; 0 .. hclen + 4)
            clLens[codeLengthOrder[i]] = cast(ubyte) br.readBits(3);
        clTable.build(clLens[], CodePolicy.complete);

        const nlit = hlit + 257;
        const total = nlit + hdist + 1;
        ubyte[286 + 30] lens;
        uint i = 0;
        while (i < total)
        {
            br.refill();
            const sym = clTable.decode(br);
            if (sym < 16)
            {
                lens[i++] = cast(ubyte) sym;
                continue;
            }
            ubyte value = 0;
            uint rep;
            if (sym == 16)
            {
                if (i == 0)
                    fail(InflateError.repeatWithoutPrevious, "length repeat with no previous length");
                value = lens[i - 1];
                rep = 3 + br.bits(2);
            }
            else if (sym == 17)
                rep = 3 + br.bits(3);
            else
                rep = 11 + br.bits(7);
            if (rep > total - i)
                fail(InflateError.repeatOverflow, "length repeat overflows the length list");
            lens[i .. i + rep] = value;
            i += rep;
        }

        if (lens[endOfBlock] == 0)
            fail(InflateError.missingEndOfBlock, "no code for the end-of-block symbol");
        litTable.build(lens[0 .. nlit], CodePolicy.litLen);
        distTable.build(lens[nlit .. total], CodePolicy.distance);
    }

    void codedBlock(ref const HuffmanTable lit, ref const HuffmanTable dist) @safe pure
    {
        for (;;)
        {
            br.refill(); // >= 56 bits: enough for a whole length/distance pair (<= 48)
            const sym = lit.decode(br);
            if (sym < 256)
            {
                if (outLen == outBuf.length)
                    reserve(1);
                outBuf[outLen++] = cast(ubyte) sym;
                continue;
            }
            if (sym == endOfBlock)
                return;
            if (sym > maxLitLenSymbol)
                fail(InflateError.invalidSymbol, "invalid literal/length symbol");

            const li = sym - 257;
            const length = lengthBase[li] + br.bits(lengthExtra[li]);

            // With no distance codes every lookup fails; report that distinctly.
            const dsym = dist.decode(br);
            if (dsym > maxDistSymbol)
                fail(InflateError.invalidSymbol, "invalid distance symbol");
            const distance = distBase[dsym] + br.bits(distExtra[dsym]);
            if (distance > outLen)
                fail(InflateError.distanceTooFar, "distance reaches before start of output");

            if (outLen + length > outBuf.length)
                reserve(length);
            copyMatch(distance, length);
        }
    }

    void copyMatch(size_t distance, size_t length) @trusted pure nothrow @nogc
    {
        ubyte* dst = outBuf.ptr + outLen;
        const(ubyte)* src = dst - distance;
        outLen += length;
        if (distance >= length)
        {
            import core.stdc.string : memcpy;

            memcpy(dst, src, length);
        }
        else if (distance == 1)
        {
            dst[0 .. length] = *src;
        }
        else
        {
            foreach (i; 0 .. length)
                dst[i] = src[i];
        }
    }
}

version (unittest)
{
    import inflate.hex : fromHex;
    import std.exception : collectException;

    private ubyte[] run(string hex) @safe pure
    {
        return decompress(fromHex(hex));
    }

    private InflateError errorOf(string hex) @safe pure
    {
        auto e = collectException!InflateException(run(hex));
        assert(e !is null, "expected an error for " ~ hex);
        return e.kind;
    }
}

// Examples from the specification.
@safe pure unittest
{
    assert(run("0300") == []);
    assert(run("010100feff41") == [0x41]);
    assert(run("4b4c4a862000") == [cast(ubyte) 97, 98, 99, 97, 98, 99, 97, 98, 99]);
    assert(errorOf("030200") == InflateError.distanceTooFar);
}

@safe pure unittest
{
    // Stored blocks: empty, LEN 0, multiple blocks.
    assert(run("010000ffff") == []);
    assert(run("000000ffff" ~ "010200fdff4142") == [0x41, 0x42]);
    // Non-zero discarded bits before LEN are ignored.
    assert(run("f9" ~ "0100feff41") == [0x41]);
}

@safe pure unittest
{
    // Errors.
    assert(errorOf("") == InflateError.truncated);
    assert(errorOf("00") == InflateError.truncated);
    assert(errorOf("07") == InflateError.invalidBlockType);
    assert(errorOf("010100ffff41") == InflateError.storedLengthMismatch);
    assert(errorOf("010100feff") == InflateError.truncated);
}

@safe pure unittest
{
    // Trailing whole bytes are rejected; spare bits in the last byte are not.
    assert(errorOf("030000") == InflateError.trailingData);
    assert(run("03fc") == []); // spare bits are not checked
    assert(errorOf("03") == InflateError.truncated);
}

@safe pure unittest
{
    // maxOutput is honoured.
    auto d = fromHex("010300fcff414243");
    assert(decompress(d, 3) == [0x41, 0x42, 0x43]);
    auto e = collectException!InflateException(decompress(d, 2));
    assert(e !is null && e.kind == InflateError.outputLimitExceeded);
    ubyte[] r;
    assert(tryDecompress(d, r) && r.length == 3);
    assert(!tryDecompress(fromHex("07"), r));
}

@safe pure unittest
{
    // Fixed block: 'a', then length 258 at distance 1 via symbol 285, then end of block.
    // Hand-encoded with a tiny bit writer.
    BitWriter w;
    w.put(1, 1);
    w.put(1, 2);
    w.code(0x30 + 'a', 8); // literals 0..143: 00110000 + sym
    w.code(0xc0 + (285 - 280), 8); // 280..287: 11000000 + (sym-280)
    w.code(0, 5); // distance symbol 0
    w.code(0, 7); // end of block (symbol 256)
    auto out_ = decompress(w.bytes);
    assert(out_.length == 259);
    foreach (b; out_)
        assert(b == 'a');
}

// Dynamic-Huffman streams produced by zlib (level 9, raw deflate).
@safe pure unittest
{
    import std.array : replicate;
    import std.string : representation;

    const text = (
        "the quick brown fox jumps over the lazy dog. ".replicate(6)
        ~ "pack my box with five dozen liquor jugs\n").representation.dup;
    assert(text.length == 310);

    // Default strategy: literals and back-references.
    assert(run("ddcbc91180201044d1bb517404e6043a020a0cb2a810bd5386e1b1ebbfae967036b71cd0"
        ~ "99ef888d1fec2da402be28a34af66a74ac6ce66ffd1a27252e746841b7ab169bbb48d2a008efcec659bea64c2f") == text);

    // A run of 1000 'a': dynamic or fixed block with long overlapping copies.
    assert(run("4b4c1c05a360140c770000") == 'a'.repeatUbyte(1000));

    // Truncating the dynamic stream anywhere is an error, never a crash.
    auto full = fromHex("ddcbc91180201044d1bb517404e6043a020a0cb2a810bd5386e1b1ebbfae967036b71cd0"
        ~ "99ef888d1fec2da402be28a34af66a74ac6ce66ffd1a27252e746841b7ab169bbb48d2a008efcec659bea64c2f");
    foreach (n; 0 .. full.length)
    {
        ubyte[] r;
        // Prefixes may rarely be valid streams, but must never throw anything else.
        cast(void) tryDecompress(full[0 .. n], r);
    }
    // Appending a byte makes it trailing data.
    auto e = collectException!InflateException(decompress(full ~ 0));
    assert(e !is null && e.kind == InflateError.trailingData);
}

version (unittest)
{
    private ubyte[] repeatUbyte(char c, size_t n) @safe pure nothrow
    {
        auto r = new ubyte[n];
        r[] = cast(ubyte) c;
        return r;
    }
}

// Hand-assembled dynamic blocks exercising the validity rules.
@safe pure unittest
{
    // Build a dynamic header + body from explicit code-length-code lengths.
    // Code-length alphabet: symbols 0 and 1 and 18 with lengths 1,2,2 is complete.
    // Literal/length lengths: 256 -> 1 (end of block only), everything else 0;
    // distance: none (one zero length). Then the block body is the single
    // code '0' for end-of-block.
    BitWriter w;
    w.put(1, 1); // BFINAL
    w.put(2, 2); // BTYPE = dynamic
    w.put(0, 5); // HLIT = 0 -> 257 lengths
    w.put(0, 5); // HDIST = 0 -> 1 length
    w.put(14, 4); // HCLEN = 14 -> 18 entries (up to symbol 1 in the order)
    // order: 16 17 18 0 8 7 9 6 10 5 11 4 12 3 13 2 14 1
    foreach (sym; [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1])
    {
        // lengths: 18 -> 2, 0 -> 2, 1 -> 1 (complete: 1/4+1/4+1/2)
        w.put(sym == 18 ? 2 : sym == 0 ? 2 : sym == 1 ? 1 : 0, 3);
    }
    // Canonical codes: len1: sym1='0'; len2: sym0='10', sym18='11'.
    // lengths: 256 zeros-ish: 138 + 118 zeros, then a 1, then a zero (distance).
    w.code(0b11, 2); w.put(138 - 11, 7); // 18: 138 zeros
    w.code(0b11, 2); w.put(118 - 11, 7); // 18: 118 zeros (total 256)
    w.code(0b0, 1); // length 1 for symbol 256
    w.code(0b10, 2); // length 0 for the distance symbol
    w.code(0b0, 1); // end-of-block
    assert(decompress(w.bytes) == []);
}

version (unittest)
{
    struct BitWriter
    {
        ubyte[] bytes;
        uint nbits;

        /// Append `n` bits of `v`, LSB first.
        void put(uint v, uint n) @safe pure
        {
            foreach (i; 0 .. n)
            {
                if (nbits % 8 == 0)
                    bytes ~= 0;
                bytes[$ - 1] |= cast(ubyte)(((v >> i) & 1) << (nbits % 8));
                ++nbits;
            }
        }

        /// Append an `n`-bit Huffman code, MSB first.
        void code(uint c, uint n) @safe pure
        {
            foreach (i; 0 .. n)
                put((c >> (n - 1 - i)) & 1, 1);
        }
    }
}
