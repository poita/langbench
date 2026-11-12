/**
 * Matrix Market reader and writer.
 *
 * The reader accepts the `coordinate` and `array` formats with the `real`,
 * `integer` and `pattern` fields and the `general`, `symmetric` and
 * `skew-symmetric` symmetries, and always yields a dense `Matrix`.
 * The writer emits `array real general` with `%.10e` values.
 */
module linalg.mmio;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;

import std.ascii : isWhite;
import std.string : toLower;

import linalg.matrix;

/// Thrown for malformed Matrix Market text.
class MatrixMarketException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

private enum Format { coordinate, array }
private enum Field { real_, integer, pattern }
private enum Symmetry { general, symmetric, skewSymmetric }

private struct Cursor
{
    const(char)[] buf;       // always NUL-terminated beyond `buf.length`
    size_t pos;

    bool atEnd() const @safe pure nothrow @nogc { return pos >= buf.length; }

    /// Next line (without terminator), or null at end of input.
    const(char)[] nextLine() @safe pure nothrow @nogc
    {
        if (atEnd)
            return null;
        const start = pos;
        while (pos < buf.length && buf[pos] != '\n')
            ++pos;
        const line = buf[start .. pos];
        if (pos < buf.length)
            ++pos;
        return line;
    }

    /// Next whitespace-delimited token, or empty at end of input.
    const(char)[] nextToken() @safe pure nothrow @nogc
    {
        while (pos < buf.length && isWhite(buf[pos]))
            ++pos;
        const start = pos;
        while (pos < buf.length && !isWhite(buf[pos]))
            ++pos;
        return buf[start .. pos];
    }
}

private const(char)[] stripWhite(const(char)[] s) @safe pure nothrow @nogc
{
    while (s.length && isWhite(s[0]))
        s = s[1 .. $];
    while (s.length && isWhite(s[$ - 1]))
        s = s[0 .. $ - 1];
    return s;
}

private size_t parseIndex(const(char)[] tok) @safe pure
{
    import std.conv : to;

    if (tok.length == 0)
        throw new MatrixMarketException("unexpected end of data");
    return tok.to!size_t;
}

private double parseValue(const(char)[] tok) @trusted
{
    // `tok` is a slice of a NUL-terminated buffer, so strtod stops at its end.
    if (tok.length == 0)
        throw new MatrixMarketException("unexpected end of data");
    const(char)* end;
    const v = strtod(tok.ptr, &end);
    if (end != tok.ptr + tok.length)
        throw new MatrixMarketException("bad number: " ~ tok.idup);
    return v;
}

/**
 * Parses Matrix Market text into a dense matrix.
 * Throws: `MatrixMarketException` on malformed input.
 */
Matrix parseMatrixMarket(const(char)[] text) @safe
{
    const buf = text ~ '\0';
    auto cur = Cursor(buf[0 .. $ - 1], 0);

    // Banner.
    const banner = cur.nextLine();
    auto bt = Cursor(banner, 0);
    if (bt.nextToken().toLower != "%%matrixmarket" || bt.nextToken().toLower != "matrix")
        throw new MatrixMarketException("missing MatrixMarket banner");
    Format format;
    switch (bt.nextToken().toLower)
    {
    case "coordinate": format = Format.coordinate; break;
    case "array": format = Format.array; break;
    default: throw new MatrixMarketException("unknown format");
    }
    Field field;
    switch (bt.nextToken().toLower)
    {
    case "real": field = Field.real_; break;
    case "integer": field = Field.integer; break;
    case "pattern": field = Field.pattern; break;
    default: throw new MatrixMarketException("unknown field");
    }
    Symmetry sym;
    switch (bt.nextToken().toLower)
    {
    case "general": sym = Symmetry.general; break;
    case "symmetric": sym = Symmetry.symmetric; break;
    case "skew-symmetric": sym = Symmetry.skewSymmetric; break;
    default: throw new MatrixMarketException("unknown symmetry");
    }

    // Comments and blanks, then the size line.
    const(char)[] sizeLine;
    while (true)
    {
        if (cur.atEnd)
            throw new MatrixMarketException("missing size line");
        const line = stripWhite(cur.nextLine());
        if (line.length == 0 || line[0] == '%')
            continue;
        sizeLine = line;
        break;
    }
    auto st = Cursor(sizeLine, 0);
    const rows = parseIndex(st.nextToken());
    const cols = parseIndex(st.nextToken());
    auto m = Matrix(rows, cols);
    const mirrored = sym != Symmetry.general;
    const double mirrorSign = sym == Symmetry.skewSymmetric ? -1.0 : 1.0;

    if (format == Format.coordinate)
    {
        const nnz = parseIndex(st.nextToken());
        foreach (_; 0 .. nnz)
        {
            const i = parseIndex(cur.nextToken());
            const j = parseIndex(cur.nextToken());
            const v = field == Field.pattern ? 1.0 : parseValue(cur.nextToken());
            if (i < 1 || i > rows || j < 1 || j > cols)
                throw new MatrixMarketException("index out of range");
            m[i - 1, j - 1] = v;
            if (mirrored && i != j)
                m[j - 1, i - 1] = mirrorSign * v;
        }
    }
    else
    {
        foreach (j; 0 .. cols)
        {
            const first = sym == Symmetry.general ? 0
                : sym == Symmetry.symmetric ? j : j + 1;
            foreach (i; first .. rows)
            {
                const v = parseValue(cur.nextToken());
                m[i, j] = v;
                if (mirrored && i != j)
                    m[j, i] = mirrorSign * v;
            }
        }
    }
    return m;
}

/// Reads and parses a Matrix Market file.
Matrix readMatrixMarket(string path) @safe
{
    import std.file : readText;

    return parseMatrixMarket(readText(path));
}

/// Formats one value like C's `printf("%.10e")`, writing `-0.0` as `0.0`.
string formatValue(double v) @trusted nothrow
{
    char[64] tmp;
    const x = v == 0.0 ? 0.0 : v;      // normalise negative zero
    const n = snprintf(tmp.ptr, tmp.length, "%.10e", x);
    return tmp[0 .. n].idup;
}

/// Renders a matrix as `array real general` text, column-major, one value per line.
string formatMatrixMarket(const Matrix m) @trusted
{
    import std.array : appender;

    auto sink = appender!(char[])();
    sink.reserve(40 + m.data.length * 18);
    sink ~= "%%MatrixMarket matrix array real general\n";
    char[32] hdr;
    sink ~= hdr[0 .. snprintf(hdr.ptr, hdr.length, "%zu %zu\n", m.rows, m.cols)];
    char[64] tmp;
    foreach (j; 0 .. m.cols)
        foreach (i; 0 .. m.rows)
        {
            const v = m.data[i * m.cols + j];
            const x = v == 0.0 ? 0.0 : v;
            sink ~= tmp[0 .. snprintf(tmp.ptr, tmp.length, "%.10e\n", x)];
        }
    return sink[].idup;
}

/// Writes a matrix to `path` in `array real general` form.
void writeMatrixMarket(string path, const Matrix m) @safe
{
    import std.file : write;

    write(path, formatMatrixMarket(m));
}

unittest
{
    assert(formatValue(1.0) == "1.0000000000e+00");
    assert(formatValue(-0.0) == "0.0000000000e+00");
    assert(formatValue(-0.007) == "-7.0000000000e-03");
    assert(formatValue(40015.422479) == "4.0015422479e+04");
    assert(formatValue(1e100) == "1.0000000000e+100");
}

unittest
{
    // Section 7.1 of the specification: three storage variants.
    const a = parseMatrixMarket("%%MatrixMarket matrix array real general\n2 2\n1.0\n3.0\n2.0\n4.0\n");
    assert(a == Matrix.fromRows([[1.0, 2.0], [3.0, 4.0]]));
    const b = parseMatrixMarket(
            "%%MatrixMarket matrix coordinate real general\n2 2 2\n1 1 0.5\n2 2 -1.5\n");
    assert(b == Matrix.fromRows([[0.5, 0.0], [0.0, -1.5]]));
    const s = parseMatrixMarket("%%MatrixMarket matrix array real symmetric\n2 2\n4.0\n2.0\n5.0\n");
    assert(s == Matrix.fromRows([[4.0, 2.0], [2.0, 5.0]]));
}

unittest
{
    const k = parseMatrixMarket("%%MatrixMarket matrix array real skew-symmetric\n3 3\n1\n2\n3\n");
    assert(k == Matrix.fromRows([[0.0, -1.0, -2.0], [1.0, 0.0, -3.0], [2.0, 3.0, 0.0]]));
    const c = parseMatrixMarket(
            "%%MatrixMarket MATRIX Coordinate Pattern Symmetric\n% comment\n\n  \n3 3 2\n2 1\n3 3\n");
    assert(c == Matrix.fromRows([[0.0, 1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]]));
    const sk = parseMatrixMarket(
            "%%MatrixMarket matrix coordinate integer skew-symmetric\n2 2 1\n2 1 5\n");
    assert(sk == Matrix.fromRows([[0.0, -5.0], [5.0, 0.0]]));
}

unittest
{
    import std.exception : assertThrown;

    const m = Matrix.fromRows([[1.5, -0.0], [3.0, 4.0e-7]]);
    assert(formatMatrixMarket(m)
            == "%%MatrixMarket matrix array real general\n2 2\n"
            ~ "1.5000000000e+00\n3.0000000000e+00\n0.0000000000e+00\n4.0000000000e-07\n");
    assertThrown!MatrixMarketException(parseMatrixMarket("garbage\n"));
    assertThrown!MatrixMarketException(
            parseMatrixMarket("%%MatrixMarket matrix array real general\n2 2\n1\n2\n"));
}
