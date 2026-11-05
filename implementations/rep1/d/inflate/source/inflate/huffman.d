/**
 * Canonical Huffman decoding tables.
 *
 * A table is indexed by the next `rootBits` bits of the stream (as held in an
 * LSB-first bit buffer, so codes are stored bit-reversed). Codes longer than
 * `rootBits` go through one second-level subtable.
 *
 * Entry layout (32 bits): bits 0..7 = number of bits to consume, bit 8 = link
 * flag, bits 16..31 = symbol (or subtable offset for a link). For a link entry
 * the low byte is the subtable index width; for an entry inside a subtable it
 * is the code length minus `rootBits`. An all-zero entry means "not a code".
 */
module inflate.huffman;

import inflate.errors;
import inflate.tables : maxCodeBits;

/// Flag marking a root entry that links to a subtable.
enum uint linkFlag = 1 << 8;

/// What kinds of incomplete code are acceptable.
enum Completeness
{
    /// Only a complete code is valid.
    complete,
    /// A complete code, or exactly one code of length 1.
    orSingle,
    /// A complete code, exactly one code of length 1, or no codes at all.
    orSingleOrEmpty,
}

/// A reusable two-level Huffman decoding table.
struct HuffmanTable
{
    /// Number of index bits of the root table.
    uint rootBits;
    /// Root table followed by subtables.
    uint[] entries;

    /// Creates a table with the given root width and storage for `capacity` entries.
    this(uint rootBits, size_t capacity) pure nothrow @safe
    {
        this.rootBits = rootBits;
        entries = new uint[capacity];
    }

    /**
     * Builds the table from per-symbol code lengths (0 = unused).
     *
     * Throws: `InflateException` with `overSubscribedCode` or `incompleteCode`
     * if the length set is not acceptable under `mode`.
     */
    void build(const(ubyte)[] lengths, Completeness mode) pure @safe
    {
        uint[maxCodeBits + 1] count;
        foreach (l; lengths)
            count[l]++;
        immutable used = cast(uint) lengths.length - count[0];
        count[0] = 0;

        // Kraft balance: `left` is the number of unassigned leaf slots at depth 15.
        int left = 1 << maxCodeBits;
        uint maxLen = 0;
        foreach (len; 1 .. maxCodeBits + 1)
        {
            left -= cast(int)(count[len] << (maxCodeBits - len));
            if (count[len]) maxLen = len;
        }
        if (left < 0)
            throw new InflateException(InflateError.overSubscribedCode);
        if (left > 0)
        {
            immutable ok = (used == 0 && mode == Completeness.orSingleOrEmpty)
                || (used == 1 && count[1] == 1 && mode != Completeness.complete);
            if (!ok)
                throw new InflateException(InflateError.incompleteCode);
        }

        // Sort symbols by (length, symbol).
        ushort[288] sorted = void;
        uint[maxCodeBits + 2] offset;
        foreach (len; 1 .. maxCodeBits + 1)
            offset[len + 1] = offset[len] + count[len];
        foreach (sym, l; lengths)
            if (l) sorted[offset[l]++] = cast(ushort) sym;

        immutable rootSize = 1u << rootBits;
        entries[0 .. rootSize] = 0;
        if (used == 0)
            return;

        // Assign canonical codes in order and fill the table.
        uint next = rootSize;       // next free subtable slot
        uint code = 0;
        uint idx = 0;
        uint curPrefix = uint.max;  // root index of the current subtable
        uint subWidth = 0;
        uint subBase = 0;
        uint[maxCodeBits + 1] remaining = count; // codes of each length not yet assigned
        foreach (len; 1 .. maxLen + 1)
        {
            foreach (_; 0 .. count[len])
            {
                immutable sym = sorted[idx++];
                immutable rev = reverseBits(code, len);
                code++;
                scope (exit) remaining[len]--;
                if (len <= rootBits)
                {
                    immutable e = (cast(uint) sym << 16) | len;
                    for (uint i = rev; i < rootSize; i += 1u << len)
                        entries[i] = e;
                }
                else
                {
                    immutable prefix = rev & (rootSize - 1);
                    if (prefix != curPrefix)
                    {
                        // Size the subtable for all codes sharing this prefix.
                        uint curr = len - rootBits;
                        int slots = 1 << curr;
                        while (curr + rootBits < maxLen)
                        {
                            slots -= cast(int) remaining[curr + rootBits];
                            if (slots <= 0) break;
                            curr++;
                            slots <<= 1;
                        }
                        subWidth = curr;
                        curPrefix = prefix;
                        entries[next .. next + (1u << subWidth)] = 0;
                        entries[prefix] = (next << 16) | linkFlag | subWidth;
                        subBase = next;
                        next += 1u << subWidth;
                    }
                    immutable e = (cast(uint) sym << 16) | (len - rootBits);
                    immutable step = 1u << (len - rootBits);
                    for (uint i = rev >> rootBits; i < (1u << subWidth); i += step)
                        entries[subBase + i] = e;
                }
            }
            code <<= 1;
        }
    }
}

/// Reverses the low `len` bits of `code`.
uint reverseBits(uint code, uint len) pure nothrow @nogc @safe
{
    uint r = 0;
    foreach (_; 0 .. len)
    {
        r = (r << 1) | (code & 1);
        code >>= 1;
    }
    return r;
}
