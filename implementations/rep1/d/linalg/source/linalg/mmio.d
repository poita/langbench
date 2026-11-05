/**
 * Matrix Market reading and writing.
 *
 * Reading accepts `coordinate` and `array` formats with `real`, `integer` or
 * `pattern` fields and `general`, `symmetric` or `skew-symmetric` symmetry,
 * and always yields a dense $(REF Matrix, linalg,matrix). Writing always
 * produces `array real general` with `%.10e` values.
 */
module linalg.mmio;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;
import std.file : read;
import linalg.matrix;

/// Thrown for input that is not a well-formed Matrix Market matrix.
class MatrixMarketException : Exception
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

private enum Layout { coordinate, array }
private enum Field { real_, integer, pattern }
private enum Symmetry { general, symmetric, skewSymmetric }

private bool isBlank(char c) pure nothrow @nogc @safe
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v';
}

private char lower(char c) pure nothrow @nogc @safe
{
    return (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
}

/// Single-pass tokenizer over an in-memory buffer that ends in a NUL byte.
private struct Scanner
{
    const(char)[] buf; // includes the trailing '\0'
    size_t pos;

    void skipWhitespace() pure nothrow @nogc
    {
        while (pos + 1 < buf.length && isBlank(buf[pos]))
            ++pos;
    }

    /// Skip whitespace and any `%` comment lines.
    void skipBlanksAndComments() pure nothrow @nogc
    {
        for (;;)
        {
            skipWhitespace();
            if (pos + 1 < buf.length && buf[pos] == '%')
            {
                while (pos + 1 < buf.length && buf[pos] != '\n')
                    ++pos;
            }
            else
                break;
        }
    }

    bool atEnd() const pure nothrow @nogc
    {
        return pos + 1 >= buf.length;
    }

    /// Next whitespace-delimited token (empty at end of input).
    const(char)[] token() pure nothrow @nogc
    {
        skipWhitespace();
        immutable start = pos;
        while (pos + 1 < buf.length && !isBlank(buf[pos]))
            ++pos;
        return buf[start .. pos];
    }

    size_t integer()
    {
        skipWhitespace();
        size_t v = 0;
        immutable start = pos;
        while (pos + 1 < buf.length && buf[pos] >= '0' && buf[pos] <= '9')
        {
            v = v * 10 + (buf[pos] - '0');
            ++pos;
        }
        if (pos == start)
            throw new MatrixMarketException("expected an integer");
        return v;
    }

    /// Correctly rounded decimal-to-double, converted in place by `strtod`
    /// (the buffer's terminating NUL guarantees it stops).
    double number()
    {
        skipWhitespace();
        if (atEnd())
            throw new MatrixMarketException("unexpected end of data");
        const(char)* end;
        immutable v = strtod(&buf[pos], &end);
        immutable consumed = end - &buf[pos];
        if (consumed == 0)
            throw new MatrixMarketException("expected a number");
        pos += consumed;
        return v;
    }
}

private bool ieq(const(char)[] tok, string word) pure nothrow @nogc @safe
{
    if (tok.length != word.length)
        return false;
    foreach (i; 0 .. word.length)
        if (lower(tok[i]) != word[i])
            return false;
    return true;
}

/**
 * Parse a Matrix Market document held in memory.
 *
 * Params:
 *   text = the file contents (any `char[]`; it is copied once to append a
 *          terminating NUL).
 * Throws: `MatrixMarketException` on malformed input.
 */
Matrix parseMatrixMarket(const(char)[] text)
{
    auto buf = new char[](text.length + 1);
    buf[0 .. text.length] = text[];
    buf[$ - 1] = '\0';
    return parseOwned(buf);
}

/// Read and parse a Matrix Market file, with one bulk read of the file.
Matrix readMatrixMarket(string path)
{
    auto raw = cast(ubyte[]) read(path);
    auto buf = cast(char[]) raw;
    buf ~= '\0';
    return parseOwned(buf);
}

private Matrix parseOwned(char[] buf)
{
    auto sc = Scanner(buf, 0);
    if (!ieq(sc.token(), "%%matrixmarket"))
        throw new MatrixMarketException("missing %%MatrixMarket banner");
    if (!ieq(sc.token(), "matrix"))
        throw new MatrixMarketException("object must be 'matrix'");
    auto fmtTok = sc.token();
    auto fieldTok = sc.token();
    auto symTok = sc.token();
    // The rest of the banner line (if any) is ignored.
    while (!sc.atEnd() && sc.buf[sc.pos] != '\n')
        ++sc.pos;

    Layout layout;
    if (ieq(fmtTok, "coordinate")) layout = Layout.coordinate;
    else if (ieq(fmtTok, "array")) layout = Layout.array;
    else throw new MatrixMarketException("unknown format");

    Field field;
    if (ieq(fieldTok, "real")) field = Field.real_;
    else if (ieq(fieldTok, "integer")) field = Field.integer;
    else if (ieq(fieldTok, "pattern")) field = Field.pattern;
    else throw new MatrixMarketException("unknown field");

    Symmetry sym;
    if (ieq(symTok, "general")) sym = Symmetry.general;
    else if (ieq(symTok, "symmetric")) sym = Symmetry.symmetric;
    else if (ieq(symTok, "skew-symmetric")) sym = Symmetry.skewSymmetric;
    else throw new MatrixMarketException("unknown symmetry");

    sc.skipBlanksAndComments();
    immutable rows = sc.integer();
    immutable cols = sc.integer();
    auto m = Matrix(rows, cols);
    auto d = m.data;
    immutable skew = sym == Symmetry.skewSymmetric;
    immutable mirror = sym != Symmetry.general;
    if (mirror && rows != cols)
        throw new MatrixMarketException("symmetric matrix must be square");

    if (layout == Layout.coordinate)
    {
        immutable nnz = sc.integer();
        foreach (e; 0 .. nnz)
        {
            immutable i = sc.integer();
            immutable j = sc.integer();
            immutable v = field == Field.pattern ? 1.0 : sc.number();
            if (i < 1 || i > rows || j < 1 || j > cols)
                throw new MatrixMarketException("index out of range");
            d[(i - 1) * cols + (j - 1)] = v;
            if (mirror && i != j)
                d[(j - 1) * cols + (i - 1)] = skew ? -v : v;
        }
    }
    else
    {
        if (!mirror)
        {
            foreach (j; 0 .. cols)
                foreach (i; 0 .. rows)
                    d[i * cols + j] = sc.number();
        }
        else
        {
            foreach (j; 0 .. cols)
            {
                foreach (i; (skew ? j + 1 : j) .. rows)
                {
                    immutable v = sc.number();
                    d[i * cols + j] = v;
                    if (i != j)
                        d[j * cols + i] = skew ? -v : v;
                }
            }
        }
    }
    return m;
}

/// Longest possible `%.10e` rendering (sign, 1 digit, point, 10 digits,
/// `e`, sign, up to 3 exponent digits) plus the newline.
private enum maxValueChars = 20;

/**
 * Render `m` in Matrix Market `array real general` form: banner, size line,
 * then every value in column-major order, one per line, as `%.10e` with
 * negative zero printed as zero. The result ends with a newline.
 */
char[] formatMatrixMarket(const Matrix m)
{
    auto out_ = new char[](64 + m.rows * m.cols * maxValueChars);
    enum banner = "%%MatrixMarket matrix array real general\n";
    out_[0 .. banner.length] = banner;
    size_t pos = banner.length;
    pos += snprintf(&out_[pos], 48, "%zu %zu\n", m.rows, m.cols);
    foreach (j; 0 .. m.cols)
    {
        foreach (i; 0 .. m.rows)
        {
            double v = m.data[i * m.cols + j];
            if (v == 0.0)
                v = 0.0; // normalise -0.0
            pos += snprintf(&out_[pos], maxValueChars + 1, "%.10e\n", v);
        }
    }
    return out_[0 .. pos];
}
