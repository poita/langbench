/// Constant tables from RFC 1951.
module inflate.constants;

/// Number of symbols in the literal/length alphabet that are valid (0..285).
enum maxLitLenSymbol = 285;
/// Number of valid distance symbols (0..29).
enum maxDistSymbol = 29;
/// The end-of-block symbol.
enum endOfBlock = 256;
/// Longest permitted Huffman code, in bits.
enum maxCodeBits = 15;

/// Base length for length symbol `257 + i`.
static immutable ushort[29] lengthBase = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
];

/// Extra bits for length symbol `257 + i`.
static immutable ubyte[29] lengthExtra = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];

/// Base distance for distance symbol `i`.
static immutable ushort[30] distBase = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
];

/// Extra bits for distance symbol `i`.
static immutable ubyte[30] distExtra = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
];

/// The order in which code-length-code lengths are stored in a dynamic block header.
static immutable ubyte[19] codeLengthOrder = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
];

/// Code lengths of the fixed literal/length code (288 symbols).
ubyte[288] fixedLitLenLengths() @safe pure nothrow @nogc
{
    ubyte[288] l = void;
    l[0 .. 144] = 8;
    l[144 .. 256] = 9;
    l[256 .. 280] = 7;
    l[280 .. 288] = 8;
    return l;
}

/// Code lengths of the fixed distance code (32 symbols).
ubyte[32] fixedDistLengths() @safe pure nothrow @nogc
{
    ubyte[32] l = 5;
    return l;
}

@safe pure nothrow @nogc unittest
{
    assert(lengthBase[28] == 258 && lengthExtra[28] == 0);
    assert(distBase[29] + (1 << distExtra[29]) - 1 == 32768);
    // The fixed literal/length code is complete: sum of 2^-len == 1.
    uint kraft;
    foreach (l; fixedLitLenLengths)
        kraft += 1u << (15 - l);
    assert(kraft == 1u << 15);
}
