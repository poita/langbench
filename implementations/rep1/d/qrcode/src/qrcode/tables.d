/**
 * Constant tables and capacity arithmetic for QR Code Model 2.
 *
 * Everything here is derived from ISO/IEC 18004: the number of codewords in
 * each version, the error-correction block structure per level and the
 * alignment-pattern coordinates.
 */
module qrcode.tables;

/// Error correction level.
enum Ecl : ubyte
{
    L, /// ~7% recovery
    M, /// ~15% recovery
    Q, /// ~25% recovery
    H, /// ~30% recovery
}

/// Smallest and largest supported symbol versions.
enum minVersion = 1;
/// ditto
enum maxVersion = 40;

/// The two-bit format-information code of an error correction level.
int formatBits(Ecl ecl) @safe pure nothrow @nogc
{
    static immutable ubyte[4] bits = [1, 0, 3, 2];
    return bits[ecl];
}

/// Number of modules per side of a version-`ver` symbol.
int symbolSize(int ver) @safe pure nothrow @nogc
{
    return 4 * ver + 17;
}

private static immutable ubyte[40][4] eccPerBlockTable = [
    // L
    [7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28,
     28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    // M
    [10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
     26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
    // Q
    [13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30,
     28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    // H
    [17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28,
     30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
];

private static immutable ubyte[40][4] numBlocksTable = [
    // L
    [1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8,
     8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
    // M
    [1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
     17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
    // Q
    [1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20,
     23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
    // H
    [1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25,
     25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
];

/// Error-correction codewords in each block of a `ver`/`ecl` symbol.
int eccCodewordsPerBlock(int ver, Ecl ecl) @safe pure nothrow @nogc
in (ver >= minVersion && ver <= maxVersion)
{
    return eccPerBlockTable[ecl][ver - 1];
}

/// Number of Reed-Solomon blocks of a `ver`/`ecl` symbol.
int numBlocks(int ver, Ecl ecl) @safe pure nothrow @nogc
in (ver >= minVersion && ver <= maxVersion)
{
    return numBlocksTable[ecl][ver - 1];
}

/// Number of modules available for codeword bits (before dropping the remainder bits).
int rawDataModules(int ver) @safe pure nothrow @nogc
in (ver >= minVersion && ver <= maxVersion)
{
    int raw = (16 * ver + 128) * ver + 64;
    if (ver >= 2)
    {
        const a = ver / 7 + 2;
        raw -= (25 * a - 10) * a - 55;
        if (ver >= 7)
            raw -= 36;
    }
    return raw;
}

/// Total number of codewords (data + error correction) in a version.
int totalCodewords(int ver) @safe pure nothrow @nogc
{
    return rawDataModules(ver) / 8;
}

/// Number of data codewords available in a `ver`/`ecl` symbol.
int dataCodewords(int ver, Ecl ecl) @safe pure nothrow @nogc
{
    return totalCodewords(ver) - eccCodewordsPerBlock(ver, ecl) * numBlocks(ver, ecl);
}

private static immutable ubyte[][40] alignmentTable = [
    [], // v1 has no alignment patterns
    [6, 18], [6, 22], [6, 26], [6, 30], [6, 34],
    [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50], [6, 30, 54],
    [6, 32, 58], [6, 34, 62], [6, 26, 46, 66], [6, 26, 48, 70], [6, 26, 50, 74],
    [6, 30, 54, 78], [6, 30, 56, 82], [6, 30, 58, 86], [6, 34, 62, 90],
    [6, 28, 50, 72, 94], [6, 26, 50, 74, 98], [6, 30, 54, 78, 102],
    [6, 28, 54, 80, 106], [6, 32, 58, 84, 110], [6, 30, 58, 86, 114],
    [6, 34, 62, 90, 118], [6, 26, 50, 74, 98, 122], [6, 30, 54, 78, 102, 126],
    [6, 26, 52, 78, 104, 130], [6, 30, 56, 82, 108, 134], [6, 34, 60, 86, 112, 138],
    [6, 30, 58, 86, 114, 142], [6, 34, 62, 90, 118, 146],
    [6, 30, 54, 78, 102, 126, 150], [6, 24, 50, 76, 102, 128, 154],
    [6, 28, 54, 80, 106, 132, 158], [6, 32, 58, 84, 110, 136, 162],
    [6, 26, 54, 82, 110, 138, 166], [6, 30, 58, 86, 114, 142, 170],
];

/// Alignment pattern centre coordinates (used for both x and y) of a version.
immutable(ubyte)[] alignmentPositions(int ver) @safe pure nothrow @nogc
in (ver >= minVersion && ver <= maxVersion)
{
    return alignmentTable[ver - 1];
}
