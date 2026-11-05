/**
 * High-level QR Code encoding: payload bytes in, finished symbol out.
 */
module qrcode.encoder;

import qrcode.gf;
import qrcode.matrix;
import qrcode.penalty;
import qrcode.segment;
import qrcode.tables;

/// Thrown when the payload does not fit in any version at the requested level.
class QrException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// A finished QR Code symbol.
struct QrCode
{
    /// Version, 1..40.
    int version_;
    /// Mask pattern used, 0..7.
    int mask;
    /// Error correction level.
    Ecl ecl;
    /// Side length in modules (`4*version_ + 17`).
    int size;
    /// Row-major modules, one byte each: 1 dark, 0 light.
    ubyte[] modules;

    /// True if the module at column `x`, row `y` is dark.
    bool isDark(int x, int y) const @safe pure nothrow @nogc
    in (x >= 0 && y >= 0 && x < size && y < size)
    {
        return modules[y * size + x] != 0;
    }

    /**
     * Append the textual form to `sink` (anything accepting `put(char[])`):
     * `version V mask M`, then one line per row (`#` dark, `.` light) and
     * a closing empty line.
     */
    void writeText(Sink)(ref Sink sink) const
    {
        import std.conv : to;
        import std.range.primitives : put;

        put(sink, "version " ~ version_.to!string ~ " mask " ~ mask.to!string ~ "\n");
        auto row = new char[size + 1];
        row[size] = '\n';
        foreach (y; 0 .. size)
        {
            const line = modules[y * size .. (y + 1) * size];
            foreach (x, v; line)
                row[x] = v ? '#' : '.';
            put(sink, row);
        }
        put(sink, "\n");
    }

    /// The textual form as a string (see $(LREF writeText)).
    string toText() const
    {
        import std.array : appender;

        auto app = appender!string();
        writeText(app);
        return app.data;
    }
}

/// Request automatic mask selection in $(LREF encode).
enum autoMask = -1;

/**
 * Interleave data blocks and append their Reed-Solomon ECC, producing the
 * final codeword sequence for the symbol.
 */
ubyte[] addEccAndInterleave(const(ubyte)[] data, int ver, Ecl ecl) @safe pure nothrow
in (data.length == dataCodewords(ver, ecl))
{
    const nBlocks = numBlocks(ver, ecl);
    const eccLen = eccCodewordsPerBlock(ver, ecl);
    const total = totalCodewords(ver);
    const shortBlocks = nBlocks - total % nBlocks;
    const shortLen = total / nBlocks - eccLen;

    const gen = rsGenerator(eccLen);
    auto ecc = new ubyte[nBlocks * eccLen];
    auto result = new ubyte[total];

    size_t k = 0;
    foreach (b; 0 .. nBlocks)
    {
        const len = shortLen + (b < shortBlocks ? 0 : 1);
        const block = data[k .. k + len];
        rsRemainder(block, gen, ecc[b * eccLen .. (b + 1) * eccLen]);
        // data codeword i of block b goes to position i*nBlocks + b (adjusted for short blocks)
        foreach (i; 0 .. len)
        {
            const pos = i < shortLen ? i * nBlocks + b
                : shortLen * nBlocks + (b - shortBlocks);
            result[pos] = block[i];
        }
        k += len;
    }
    const dataTotal = data.length;
    foreach (b; 0 .. nBlocks)
        foreach (i; 0 .. eccLen)
            result[dataTotal + i * nBlocks + b] = ecc[b * eccLen + i];
    return result;
}

/**
 * Encode `text` (treated as raw bytes; mode chosen automatically) at
 * the given error correction level.
 *
 * Params:
 *   text = payload bytes (e.g. UTF-8)
 *   ecl  = error correction level
 *   mask = 0..7 to force a mask pattern, or `autoMask` to pick the one
 *          with the lowest penalty (lowest number on ties)
 * Throws: `QrException` if the payload does not fit in version 40, or
 *         the mask is out of range.
 */
QrCode encode(const(ubyte)[] text, Ecl ecl, int mask = autoMask) @safe pure
{
    if (mask < autoMask || mask > 7)
        throw new QrException("mask must be 0..7 or auto");
    const mode = selectMode(text);
    const ver = selectVersion(mode, text.length, ecl);
    if (ver < 0)
        throw new QrException("data too long for any QR Code version");

    const data = packData(text, mode, ver, ecl);
    const codewords = addEccAndInterleave(data, ver, ecl);

    auto base = buildFunctionPatterns(ver, ecl);
    placeCodewords(base, codewords);

    QrCode code;
    code.version_ = ver;
    code.ecl = ecl;
    code.size = base.size;
    code.modules = new ubyte[base.modules.length];

    if (mask != autoMask)
    {
        renderMask(base, code.modules, ecl, mask);
        code.mask = mask;
        return code;
    }

    auto scratch = new ubyte[base.modules.length];
    int best = int.max;
    foreach (m; 0 .. 8)
    {
        renderMask(base, scratch, ecl, m);
        const p = penaltyScore(scratch, base.size);
        if (p < best)
        {
            best = p;
            code.mask = m;
            code.modules[] = scratch[];
        }
    }
    return code;
}

/// Convenience overload taking a `string` (its UTF-8 bytes are encoded).
QrCode encode(string text, Ecl ecl, int mask = autoMask) @trusted pure
{
    return encode(cast(const(ubyte)[]) text, ecl, mask);
}
