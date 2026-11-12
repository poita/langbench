/// The top-level encoding pipeline: text in, finished module matrix out.
module qrcode.encoder;

import qrcode.bitbuffer;
import qrcode.matrix;
import qrcode.penalty;
import qrcode.reedsolomon;
import qrcode.segment;
import qrcode.tables;

/// Pass as the `mask` argument of `encode` to choose the mask by penalty scoring.
enum autoMask = -1;

/// A finished QR Code symbol.
struct QrCode
{
    /// Version (1..40).
    int ver;
    /// Mask pattern used (0..7).
    int mask;
    /// Error correction level.
    Ecl ecl;
    /// Side length in modules, `4 * ver + 17`.
    int size;
    /// Row-major modules, `size * size` entries; 1 = dark, 0 = light. No quiet zone.
    ubyte[] modules;

    /// Whether the module at column `x`, row `y` is dark.
    bool isDark(int x, int y) const @safe pure nothrow @nogc { return modules[y * size + x] != 0; }

    /// Renders the symbol as `size` lines of `#` / `.` terminated by newlines.
    string toRows() const @safe pure nothrow
    {
        auto s = new char[size * (size + 1)];
        size_t k = 0;
        foreach (y; 0 .. size)
        {
            foreach (x; 0 .. size)
                s[k++] = modules[y * size + x] ? '#' : '.';
            s[k++] = '\n';
        }
        return (() @trusted => cast(string) s)();
    }

    /// Renders the header line followed by the rows, as in the command-line tool's output.
    string toText() const @safe pure
    {
        import std.conv : text;
        return text("version ", ver, " mask ", mask, "\n", toRows());
    }
}

/// Splits `data` into Reed-Solomon blocks, appends ECC and interleaves everything into the final codeword sequence.
ubyte[] addEccAndInterleave(const(ubyte)[] data, int ver, Ecl ecl) @safe pure nothrow
in (data.length == dataCodewords(ver, ecl))
{
    const nBlocks = numBlocks(ver, ecl);
    const eccLen = eccCodewordsPerBlock(ver, ecl);
    const total = totalCodewords(ver);
    const shortBlocks = nBlocks - total % nBlocks;
    const shortLen = total / nBlocks - eccLen; // data codewords in a short block

    const generator = generatorPolynomial(eccLen);
    const(ubyte)[][] blocks;
    ubyte[][] eccs;
    size_t offset = 0;
    foreach (b; 0 .. nBlocks)
    {
        const len = shortLen + (b < shortBlocks ? 0 : 1);
        auto block = data[offset .. offset + len];
        offset += len;
        blocks ~= block;
        eccs ~= remainder(block, generator);
    }

    auto result = new ubyte[total];
    size_t k = 0;
    foreach (i; 0 .. shortLen + 1)
        foreach (block; blocks)
            if (i < block.length)
                result[k++] = block[i];
    foreach (i; 0 .. eccLen)
        foreach (ecc; eccs)
            result[k++] = ecc[i];
    assert(k == total);
    return result;
}

/**
 * Encodes a byte string (interpreted as UTF-8 text) into a QR Code symbol.
 *
 * Params:
 *   data = payload bytes; the mode (numeric / alphanumeric / byte) is chosen automatically
 *   ecl  = error correction level
 *   mask = a mask pattern 0..7, or `autoMask` to pick the lowest-penalty one (ties go to the lower number)
 *
 * Throws: `DataTooLongException` if the payload fits no version at `ecl`.
 */
QrCode encode(const(ubyte)[] data, Ecl ecl, int mask = autoMask) @safe pure
in (mask == autoMask || (mask >= 0 && mask < 8))
{
    const mode = selectMode(data);
    const ver = chooseVersion(mode, data.length, ecl);

    BitBuffer bits;
    appendSegment(bits, data, mode, ver);
    terminateAndPad(bits, dataCodewords(ver, ecl));
    const codewords = addEccAndInterleave(bits.bytes, ver, ecl);

    auto grid = drawFunctionPatterns(ver);
    placeData(grid, codewords);
    const n = grid.size;

    int bestMask = mask;
    ubyte[] bestCells;
    if (mask == autoMask)
    {
        int bestScore = int.max;
        foreach (m; 0 .. 8)
        {
            auto cells = grid.cells.dup;
            applyMask(cells, grid.isFunction, n, m);
            drawFormat(cells, n, ecl, m);
            const score = penaltyScore(cells, n);
            if (score < bestScore)
            {
                bestScore = score;
                bestMask = m;
                bestCells = cells;
            }
        }
    }
    else
    {
        bestCells = grid.cells.dup;
        applyMask(bestCells, grid.isFunction, n, mask);
        drawFormat(bestCells, n, ecl, mask);
    }
    return QrCode(ver, bestMask, ecl, n, bestCells);
}

/// Convenience overload for text.
QrCode encodeText(string text, Ecl ecl, int mask = autoMask) @safe pure
{
    return encode(cast(const(ubyte)[]) text, ecl, mask);
}

version (unittest)
{
    private string[] rowsOf(string s) @safe pure
    {
        import std.string : splitLines;
        return s.splitLines();
    }
}

@safe pure unittest
{
    // Worked example 1 of the specification.
    auto qr = encodeText("HELLO WORLD", Ecl.medium, 0);
    assert(qr.ver == 1 && qr.mask == 0 && qr.size == 21);
    assert(qr.toRows() ==
        "#######...#.#.#######\n" ~
        "#.....#.###...#.....#\n" ~
        "#.###.#...#.#.#.###.#\n" ~
        "#.###.#...#.#.#.###.#\n" ~
        "#.###.#.#.###.#.###.#\n" ~
        "#.....#..###..#.....#\n" ~
        "#######.#.#.#.#######\n" ~
        ".....................\n" ~
        "#.#.#.#..#..#...#..#.\n" ~
        ".####...#..#....#...#\n" ~
        "...#######.#..#.##...\n" ~
        "####.#.##..###.#.###.\n" ~
        ".#..####.#.#..###.#.#\n" ~
        "........#.#...#...#.#\n" ~
        "#######.....#..#.##..\n" ~
        "#.....#..##...##.#...\n" ~
        "#.###.#.##..#.#######\n" ~
        "#.###.#...##.#.#...#.\n" ~
        "#.###.#.####.###.#..#\n" ~
        "#.....#....###...#.##\n" ~
        "#######.##.#.###....#\n");
    // The automatic choice agrees (penalties 311 406 442 463 367 528 395 445).
    assert(encodeText("HELLO WORLD", Ecl.medium).mask == 0);
}

@safe pure unittest
{
    // Worked example 2: numeric, automatic mask.
    auto qr = encodeText("01234567", Ecl.low);
    assert(qr.ver == 1 && qr.mask == 3);
    assert(rowsOf(qr.toRows())[8] == "####..#.#.#..#..###.#");
}

@safe pure unittest
{
    // Worked example 3: byte mode with multi-byte UTF-8.
    auto qr = encodeText("héllo", Ecl.high, 5);
    assert(qr.ver == 1 && qr.mask == 5);
    assert(rowsOf(qr.toText())[0] == "version 1 mask 5");
    assert(rowsOf(qr.toText())[1] == "#######.####..#######");
}

@safe pure unittest
{
    // Version 40 at the capacity limit, and one byte beyond it.
    import std.exception : assertThrown;
    import std.array : replicate;
    auto qr = encodeText("a".replicate(2953), Ecl.low, 0);
    assert(qr.ver == 40 && qr.size == 177 && qr.modules.length == 177 * 177);
    assertThrown!DataTooLongException(encodeText("a".replicate(2954), Ecl.low));
}

@safe pure unittest
{
    // Interleaving: version 5-Q has 4 blocks (2 short + 2 long); total length must be preserved.
    import std.range : iota;
    import std.array : array;
    import std.algorithm : map;
    auto data = iota(0, dataCodewords(5, Ecl.quartile)).map!(i => cast(ubyte) i).array;
    auto cw = addEccAndInterleave(data, 5, Ecl.quartile);
    assert(cw.length == totalCodewords(5));
    // First four codewords are the first codeword of each block.
    assert(cw[0] == 0 && cw[1] == 15 && cw[2] == 30 && cw[3] == 46);
}
