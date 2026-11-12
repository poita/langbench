/**
 * Canonical Huffman codes and two-level decoding tables.
 *
 * A table has a root level indexed by the next `rootBits` stream bits. A code
 * no longer than `rootBits` fills every root slot whose low bits match the
 * (bit-reversed) code. A longer code's root slot is a link to a second-level
 * table indexed by the following bits. Every symbol therefore decodes with
 * one or two lookups, and building a table costs
 * O(symbols + 2^rootBits + second-level sizes).
 */
module inflate.huffman;

import inflate.bitreader;
import inflate.constants : maxCodeBits;
import inflate.error;

/// Which incomplete code-length sets are acceptable (RFC 1951 / zlib rules).
enum CodePolicy
{
    /// Must be complete.
    complete,
    /// Complete, or a single code of length 1.
    litLen,
    /// Complete, empty, or a single code of length 1.
    distance,
}

/// A decoding table for one Huffman code.
struct HuffmanTable
{
    // Entry layout: bits 0..3 = code length (root: whole code, or for a link
    // the second-level index width; second level: bits beyond the root),
    // bit 4 = link flag, bits 8.. = symbol (or second-level offset).
    // Zero means "no code".
    private enum linkFlag = 16u;

    private uint[] entries;
    private uint rootBits;
    private uint rootMask;

    /// Allocate a table for codes of at most `maxSymbols` symbols using a `rootBits`-bit root.
    this(uint rootBits, uint maxSymbols) @safe pure nothrow
    {
        assert(rootBits >= 1 && rootBits <= maxCodeBits);
        this.rootBits = rootBits;
        this.rootMask = (1u << rootBits) - 1;
        // Each second-level table starts at a distinct root slot and holds
        // at most 2^(15 - rootBits) entries; at most `maxSymbols` of them.
        entries = new uint[(1u << rootBits) + maxSymbols * (1u << (maxCodeBits - rootBits))];
    }

    /**
     * Rebuild the table from `lengths` (one code length 0..15 per symbol).
     * Throws if the lengths are over-subscribed, or incomplete in a way
     * `policy` does not allow.
     */
    void build(const(ubyte)[] lengths, CodePolicy policy) @safe pure
    {
        assert(lengths.length <= ushort.max);
        uint[maxCodeBits + 1] count;
        foreach (l; lengths)
            ++count[l];
        const used = cast(uint) lengths.length - count[0];
        count[0] = 0;

        // Kraft check, scaled by 2^15.
        int left = 1;
        uint longest = 0;
        foreach (len; 1 .. maxCodeBits + 1)
        {
            left = (left << 1) - cast(int) count[len];
            if (left < 0)
                fail(InflateError.oversubscribedCode, "over-subscribed set of code lengths");
            if (count[len])
                longest = len;
        }
        if (left > 0)
        {
            const single = used == 1 && count[1] == 1;
            const ok = (policy == CodePolicy.litLen && single)
                || (policy == CodePolicy.distance && (used == 0 || single));
            if (!ok)
                fail(InflateError.incompleteCode, "incomplete set of code lengths");
        }

        // Symbols sorted by (length, symbol).
        uint[maxCodeBits + 2] offs;
        foreach (len; 1 .. maxCodeBits + 1)
            offs[len + 1] = offs[len] + count[len];
        ushort[288] sortedBuf = void;
        assert(lengths.length <= sortedBuf.length);
        foreach (sym, l; lengths)
            if (l)
                sortedBuf[offs[l]++] = cast(ushort) sym;
        const sorted = sortedBuf[0 .. used];

        entries[0 .. 1u << rootBits] = 0;
        uint nextFree = 1u << rootBits;
        uint[maxCodeBits + 1] remaining = count; // codes of each length not yet placed
        uint code = 0;
        uint idx = 0;
        uint curRoot = uint.max, curBase, curBits;
        foreach (len; 1 .. longest + 1)
        {
            foreach (_; 0 .. count[len])
            {
                const sym = sorted[idx++];
                const rev = reverseBits(code, len);
                ++code;
                scope (exit)
                    --remaining[len];
                if (len <= rootBits)
                {
                    const e = (cast(uint) sym << 8) | len;
                    for (uint i = rev; i <= rootMask; i += 1u << len)
                        entries[i] = e;
                    continue;
                }
                const root = rev & rootMask;
                if (root != curRoot)
                {
                    // Size the second-level table to the longest code sharing this prefix.
                    curBits = len - rootBits;
                    int room = 1 << curBits;
                    for (uint l2 = len; ; )
                    {
                        room -= cast(int) remaining[l2];
                        if (room <= 0 || l2 == longest)
                            break;
                        ++l2;
                        ++curBits;
                        room <<= 1;
                    }
                    curRoot = root;
                    curBase = nextFree;
                    nextFree += 1u << curBits;
                    if (nextFree > entries.length)
                        fail(InflateError.oversubscribedCode, "internal table overflow");
                    entries[curBase .. nextFree] = 0;
                    entries[root] = (curBase << 8) | linkFlag | curBits;
                }
                const sublen = len - rootBits;
                const e = (cast(uint) sym << 8) | sublen;
                for (uint i = rev >> rootBits; i < (1u << curBits); i += 1u << sublen)
                    entries[curBase + i] = e;
            }
            code <<= 1;
        }
    }

    /**
     * Decode one symbol. The caller must have called `br.refill()` so that at
     * least 15 bits (or all remaining bits) are buffered.
     */
    uint decode(ref BitReader br) const @safe pure
    {
        const peek = cast(uint) br.buf;
        uint e = entries[peek & rootMask];
        uint len = e & 15;
        if (e & linkFlag)
        {
            e = entries[(e >> 8) + ((peek >> rootBits) & ((1u << len) - 1))];
            const sub = e & 15;
            len = sub ? rootBits + sub : 0;
        }
        if (len == 0)
            fail(InflateError.invalidCode, "bit pattern matches no Huffman code");
        br.consume(len);
        return e >> 8;
    }
}

/// Reverse the low `n` bits of `v`.
uint reverseBits(uint v, uint n) @safe pure nothrow @nogc
{
    uint r;
    foreach (_; 0 .. n)
    {
        r = (r << 1) | (v & 1);
        v >>= 1;
    }
    return r;
}

version (unittest)
{
    import std.exception : assertThrown, collectException;

    private uint[] decodeAll(ref HuffmanTable t, const(ubyte)[] bytes, size_t n) @safe pure
    {
        auto br = BitReader(bytes);
        uint[] r;
        foreach (_; 0 .. n)
        {
            br.refill();
            r ~= t.decode(br);
        }
        return r;
    }
}

@safe pure unittest
{
    // RFC 1951 example: lengths (3,3,3,3,3,2,4,4) for symbols A..H.
    // Codes: A 010, B 011, C 100, D 101, E 110, F 00, G 1110, H 1111.
    auto t = HuffmanTable(3, 8);
    t.build([3, 3, 3, 3, 3, 2, 4, 4], CodePolicy.complete);
    // Stream bits: F=00, G=1110, A=010 -> 0,0,1,1,1,0,0,1,0
    // byte0 (bit 0 first) = 0,0,1,1,1,0,0,1 = 0b1001_1100; byte1 = 0
    assert(decodeAll(t, [0b1001_1100, 0b0], 3) == [5, 6, 0]);
}

@safe pure unittest
{
    // Long codes force second-level tables (2-bit root, lengths up to 5).
    auto t = HuffmanTable(2, 6);
    t.build([1, 2, 3, 4, 5, 5], CodePolicy.complete);
    // codes: 0, 10, 110, 1110, 11110, 11111
    // Stream: 0 | 10 | 110 | 11110 -> 0 1 0 1 1 0 1 1 1 1 0
    // byte0 = 0,1,0,1,1,0,1,1 = 0b1101_1010, byte1 = 1,1,0 = 0b011
    assert(decodeAll(t, [0b1101_1010, 0b011], 4) == [0, 1, 2, 4]);
    assert(decodeAll(t, [0xff, 0xff], 3) == [5, 5, 5]);
}

@safe pure unittest
{
    auto t = HuffmanTable(8, 32);
    // over-subscribed
    auto e = collectException!InflateException(t.build([1, 1, 1], CodePolicy.complete));
    assert(e !is null && e.kind == InflateError.oversubscribedCode);
    // incomplete
    e = collectException!InflateException(t.build([2, 2], CodePolicy.complete));
    assert(e !is null && e.kind == InflateError.incompleteCode);
    e = collectException!InflateException(t.build([2, 2], CodePolicy.litLen));
    assert(e !is null && e.kind == InflateError.incompleteCode);
    // single 1-bit code allowed for litLen / distance, but not complete
    t.build([0, 1], CodePolicy.litLen);
    t.build([0, 1], CodePolicy.distance);
    assertThrown!InflateException(t.build([0, 1], CodePolicy.complete));
    // a single code of length 2 is never allowed
    assertThrown!InflateException(t.build([0, 2], CodePolicy.distance));
    // empty only for distance
    t.build([0, 0, 0], CodePolicy.distance);
    assertThrown!InflateException(t.build([0, 0, 0], CodePolicy.litLen));
}

@safe pure unittest
{
    // Single code of length 1 (symbol 1): '0' is valid, '1' is not.
    auto t = HuffmanTable(8, 32);
    t.build([0, 1], CodePolicy.distance);
    auto br = BitReader([0b10]);
    br.refill();
    assert(t.decode(br) == 1);
    auto e = collectException!InflateException(t.decode(br));
    assert(e !is null && e.kind == InflateError.invalidCode);
}

@safe pure unittest
{
    // A complete 15-bit code: lengths 1,2,...,14,15,15.
    ubyte[16] l;
    foreach (i; 0 .. 14)
        l[i] = cast(ubyte)(i + 1);
    l[14] = 15;
    l[15] = 15;
    auto t = HuffmanTable(10, 16);
    t.build(l[], CodePolicy.complete);
    // Symbol 15 is the code 1^15, symbol 14 is 1^14 0.
    // 15 ones, then 14 ones and a zero: bits 0..28 set, bit 29 clear.
    ubyte[] bytes = [0xff, 0xff, 0xff, 0x1f];
    auto br = BitReader(bytes);
    br.refill();
    assert(t.decode(br) == 15);
    assert(t.decode(br) == 14);
}

@safe pure unittest
{
    assert(reverseBits(0b110, 3) == 0b011);
    assert(reverseBits(1, 15) == 1 << 14);
}
