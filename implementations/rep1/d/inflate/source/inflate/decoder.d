/// The DEFLATE decoder proper.
module inflate.decoder;

import inflate.bitreader;
import inflate.errors;
import inflate.huffman;
import inflate.tables;

/**
 * Decompresses a raw DEFLATE stream (RFC 1951, no zlib/gzip wrapper).
 *
 * The stream must end exactly at the end of the final block, apart from the
 * unused bits of its last byte; any further whole byte is an error.
 *
 * Params:
 *   data     = the compressed bytes
 *   sizeHint = expected decompressed size, used to pre-size the output buffer
 *
 * Returns: the decompressed bytes.
 *
 * Throws: `InflateException` if the stream is malformed.
 */
ubyte[] decompress(const(ubyte)[] data, size_t sizeHint = 0) @safe
{
    auto inflater = Inflater(sizeHint);
    return inflater.run(data);
}

///
@safe unittest
{
    // One stored block holding the byte 0x41.
    immutable ubyte[] stream = [0x01, 0x01, 0x00, 0xfe, 0xff, 0x41];
    assert(decompress(stream) == [0x41]);
}

/**
 * Non-throwing variant of `decompress`.
 *
 * Returns: `true` and sets `result` on success; `false` and sets `error` if
 * the stream is malformed.
 */
bool tryDecompress(const(ubyte)[] data, out ubyte[] result, out InflateError error) @safe
{
    try
    {
        result = decompress(data);
        return true;
    }
    catch (InflateException e)
    {
        error = e.error;
        return false;
    }
}

/**
 * A decoder with reusable Huffman table storage.
 *
 * Decoding many streams with one `Inflater` avoids reallocating the tables.
 */
struct Inflater
{
    private HuffmanTable lit, dist, clen;
    private HuffmanTable fixedLit, fixedDist;
    private bool fixedReady;
    private ubyte[] output;
    private size_t outLen;

    /// Creates a decoder; `sizeHint` is the expected output size (0 = unknown).
    this(size_t sizeHint) @safe
    {
        lit = HuffmanTable(litRootBits, 2048);
        dist = HuffmanTable(distRootBits, 1024);
        clen = HuffmanTable(clenRootBits, 1 << clenRootBits);
        output = new ubyte[sizeHint ? sizeHint : 1 << 16];
    }

    /// Decodes one complete stream; see `decompress`. The decoder may be reused afterwards.
    ubyte[] run(const(ubyte)[] data) @safe
    {
        auto br = BitReader(data);
        outLen = 0;
        bool last;
        do
        {
            immutable header = br.take(3);
            last = (header & 1) != 0;
            final switch (header >> 1)
            {
            case 0: storedBlock(br); break;
            case 1: fixedBlock(br); break;
            case 2: dynamicBlock(br); break;
            case 3: throw new InflateException(InflateError.invalidBlockType);
            }
        }
        while (!last);

        if (!br.atEnd)
            throw new InflateException(InflateError.trailingData);
        auto result = output[0 .. outLen];
        output = null; // hand the buffer to the caller
        return result;
    }

    private enum litRootBits = 10;
    private enum distRootBits = 8;
    private enum clenRootBits = 7;

    private void storedBlock(ref BitReader br) @safe
    {
        br.alignToByte();
        br.refill();
        immutable len = br.take(16);
        immutable nlen = br.take(16);
        if ((len ^ nlen) != 0xFFFF)
            throw new InflateException(InflateError.storedLengthMismatch);
        auto bytes = br.takeBytes(len);
        reserve(len);
        output[outLen .. outLen + len] = bytes[];
        outLen += len;
    }

    private void reserve(size_t extra) @safe
    {
        output = grow(output, outLen, extra);
    }

    private void fixedBlock(ref BitReader br) @safe
    {
        if (!fixedReady)
        {
            ubyte[fixedLitSymbols] ll = void;
            ll[0 .. 144] = 8;
            ll[144 .. 256] = 9;
            ll[256 .. 280] = 7;
            ll[280 .. 288] = 8;
            ubyte[fixedDistSymbols] dl = 5;
            fixedLit = HuffmanTable(litRootBits, 2048);
            fixedDist = HuffmanTable(distRootBits, 1024);
            fixedLit.build(ll[], Completeness.complete);
            fixedDist.build(dl[], Completeness.complete);
            fixedReady = true;
        }
        decodeSymbols(br, fixedLit, fixedDist);
    }

    private void dynamicBlock(ref BitReader br) @safe
    {
        immutable nlit = br.take(5) + 257;
        immutable ndist = br.take(5) + 1;
        immutable nclen = br.take(4) + 4;
        if (nlit > 286 || ndist > 30)
            throw new InflateException(InflateError.tooManyCodes);

        ubyte[19] clLens;
        foreach (i; 0 .. nclen)
            clLens[codeLengthOrder[i]] = cast(ubyte) br.take(3);
        clen.build(clLens[], Completeness.complete);

        immutable total = nlit + ndist;
        ubyte[286 + 30] lens;
        uint n = 0;
        while (n < total)
        {
            br.refill();
            immutable e = clen.entries[br.peek(clenRootBits)];
            if (e == 0)
                throw new InflateException(InflateError.invalidCode);
            br.drop(e & 0xFF);
            immutable sym = e >> 16;
            if (sym < 16)
            {
                lens[n++] = cast(ubyte) sym;
                continue;
            }
            ubyte value = 0;
            uint repeat;
            if (sym == 16)
            {
                if (n == 0)
                    throw new InflateException(InflateError.repeatWithoutPrevious);
                value = lens[n - 1];
                repeat = 3 + br.take(2);
            }
            else if (sym == 17)
                repeat = 3 + br.take(3);
            else
                repeat = 11 + br.take(7);
            if (repeat > total - n)
                throw new InflateException(InflateError.repeatOverflow);
            lens[n .. n + repeat] = value;
            n += repeat;
        }

        if (lens[256] == 0)
            throw new InflateException(InflateError.missingEndOfBlock);
        lit.build(lens[0 .. nlit], Completeness.orSingle);
        dist.build(lens[nlit .. total], Completeness.orSingleOrEmpty);
        decodeSymbols(br, lit, dist);
    }

    /// Decodes literal/length and distance symbols up to the end-of-block code.
    private void decodeSymbols(ref BitReader brRef, ref const HuffmanTable litTab,
        ref const HuffmanTable distTab) @safe
    {
        // Work on local copies so the hot state lives in registers.
        auto br = brRef;
        auto o = output;
        size_t n = outLen;

        for (;;)
        {
            br.refill(); // >= 56 bits unless the input is nearly exhausted
            immutable sym = decodeSymbol(br, litTab);
            if (sym < 256)
            {
                if (n == o.length)
                    o = grow(o, n, 1);
                o[n++] = cast(ubyte) sym;
                continue;
            }
            if (sym == 256)
                break;
            if (sym > 285)
                throw new InflateException(InflateError.invalidSymbol);

            immutable ls = sym - 257;
            immutable lextra = lengthExtra[ls];
            immutable length = lengthBase[ls] + br.peek(lextra);
            br.drop(lextra);

            immutable ds = decodeSymbol(br, distTab);
            if (ds > 29)
                throw new InflateException(InflateError.invalidSymbol);
            immutable dextra = distExtra[ds];
            immutable distance = distBase[ds] + br.peek(dextra);
            br.drop(dextra);

            if (distance > n)
                throw new InflateException(InflateError.distanceTooFar);
            if (length > o.length - n)
                o = grow(o, n, length);

            if (distance >= length)
                o[n .. n + length] = o[n - distance .. n - distance + length];
            else
                foreach (i; n .. n + length)
                    o[i] = o[i - distance];
            n += length;
        }

        brRef = br;
        output = o;
        outLen = n;
    }
}

/// Looks up and consumes one Huffman-coded symbol.
pragma(inline, true)
private uint decodeSymbol(ref BitReader br, ref const HuffmanTable t) @safe
{
    uint e = t.entries[br.peek(t.rootBits)];
    if (e & linkFlag)
    {
        br.drop(t.rootBits);
        e = t.entries[(e >> 16) + br.peek(e & 0xFF)];
    }
    if (e == 0)
        throw new InflateException(InflateError.invalidCode);
    br.drop(e & 0xFF);
    return e >> 16;
}

/// Returns `buf` (or a larger copy) with room for `extra` more bytes after `used`.
private ubyte[] grow(ubyte[] buf, size_t used, size_t extra) pure nothrow @safe
{
    immutable need = used + extra;
    if (need <= buf.length)
        return buf;
    size_t newLen = buf.length * 2;
    if (newLen < need)
        newLen = need;
    buf.length = newLen;
    return buf;
}
