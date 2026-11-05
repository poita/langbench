/// Unit tests for inflate.huffman.
module huffman_test;

import std.exception : assertThrown;

import inflate.errors;
import inflate.huffman;

private InflateError buildError(const(ubyte)[] lengths, Completeness mode, uint root = 4) @safe
{
    auto t = HuffmanTable(root, 4096);
    try
        t.build(lengths, mode);
    catch (InflateException e)
        return e.error;
    assert(false, "expected failure");
}

@safe unittest
{
    assert(reverseBits(0b110, 3) == 0b011);
    assert(reverseBits(1, 15) == 1 << 14);
    assert(reverseBits(0, 5) == 0);
}

@safe unittest
{
    // RFC 1951 example: lengths (3,3,3,3,3,2,4,4) -> F=00, A=010, ... 
    auto t = HuffmanTable(9, 512);
    t.build([3, 3, 3, 3, 3, 2, 4, 4], Completeness.complete);
    // Symbol 5 (F) has code 00: any index with low 2 bits zero.
    foreach (i; 0 .. 128)
    {
        immutable e = t.entries[i * 4];
        assert((e >> 16) == 5 && (e & 0xFF) == 2);
    }
    // Symbol 0 (A) has code 010, reversed 010 -> index 2 (low three bits).
    assert((t.entries[2] >> 16) == 0 && (t.entries[2] & 0xFF) == 3);
    // Symbol 6 (G) has code 1110 -> reversed 0111 = 7.
    assert((t.entries[7] >> 16) == 6 && (t.entries[7] & 0xFF) == 4);
}

@safe unittest
{
    // Codes longer than the root width go through subtables.
    ubyte[] lengths = [1, 2, 3, 4, 5, 6, 7, 8, 8];
    auto t = HuffmanTable(4, 512);
    t.build(lengths, Completeness.complete);
    // Symbol 8 is the all-ones 8-bit code: root index 15 links to a subtable.
    immutable root = t.entries[15];
    assert(root & linkFlag);
    immutable width = root & 0xFF;
    assert(width == 4);
    immutable sub = t.entries[(root >> 16) + 15];
    assert((sub >> 16) == 8 && (sub & 0xFF) == 4);
}

@safe unittest
{
    assert(buildError([1, 1, 1], Completeness.complete) == InflateError.overSubscribedCode);
    assert(buildError([1, 2], Completeness.complete) == InflateError.incompleteCode);
    assert(buildError([2], Completeness.orSingle) == InflateError.incompleteCode);
    assert(buildError([], Completeness.orSingle) == InflateError.incompleteCode);
    assert(buildError([1, 1, 1], Completeness.orSingleOrEmpty) == InflateError.overSubscribedCode);
}

@safe unittest
{
    // The permitted incomplete codes.
    auto t = HuffmanTable(4, 64);
    t.build([0, 0, 1], Completeness.orSingle);
    assert((t.entries[0] >> 16) == 2 && (t.entries[0] & 0xFF) == 1);
    assert(t.entries[1] == 0);           // the bit pattern 1 is not a code
    t.build([0, 0, 0], Completeness.orSingleOrEmpty);
    assert(t.entries[0] == 0 && t.entries[1] == 0);
}
