/**
 * The batch driver: reads a sequence of patterns, each followed by subject
 * lines, and writes one result line per subject.
 *
 * Input format (every line ends with `\n`):
 * ---
 * N
 * pattern_1
 * M_1
 * subject_1_1
 * ...
 * ---
 * Output: `no`, or `match <start> <end>` followed by `|<gs>,<ge>` / `|-`
 * for each group.
 */
module regex.batch;

import core.stdc.string : memchr;
import regex.regex;

/// Thrown when the batch input does not follow the expected format.
class BatchFormatException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// Receives output text in chunks.
alias Sink = void delegate(const(char)[] chunk);

/// Appends the decimal representation of `v` to `buf`.
void putNumber(ref char[] buf, size_t v) pure nothrow @safe
{
    char[20] tmp = void;
    size_t i = tmp.length;
    do
    {
        tmp[--i] = cast(char)('0' + v % 10);
        v /= 10;
    }
    while (v != 0);
    buf ~= tmp[i .. $];
}

/**
 * Appends the result line for `m` (without the trailing newline) to `buf`,
 * in the format described in the module documentation.
 */
void formatMatch(ref char[] buf, in Match m) pure nothrow @safe
{
    if (!m.matched)
    {
        buf ~= "no";
        return;
    }
    buf ~= "match ";
    putNumber(buf, m.start);
    buf ~= ' ';
    putNumber(buf, m.end);
    foreach (c; m.captures)
    {
        buf ~= '|';
        if (!c.set)
            buf ~= '-';
        else
        {
            putNumber(buf, c.start);
            buf ~= ',';
            putNumber(buf, c.end);
        }
    }
}

private struct LineReader
{
    const(char)[] data;
    size_t pos;

    /// Returns the next line without its terminator. The final line may lack one.
    const(char)[] next() @trusted
    {
        if (pos >= data.length)
            throw new BatchFormatException("unexpected end of input");
        auto rest = data[pos .. $];
        auto p = cast(const(char)*) memchr(rest.ptr, '\n', rest.length);
        size_t len = p is null ? rest.length : p - rest.ptr;
        auto line = rest[0 .. len];
        pos += len + (p is null ? 0 : 1);
        return line;
    }

    size_t nextInt()
    {
        auto line = next();
        if (line.length == 0 || line.length > 18)
            throw new BatchFormatException("expected an integer");
        size_t v = 0;
        foreach (c; line)
        {
            if (c < '0' || c > '9')
                throw new BatchFormatException("expected an integer");
            v = v * 10 + (c - '0');
        }
        return v;
    }
}

/**
 * Processes `input` in the batch format and passes the output to `sink`
 * in chunks. Throws `BatchFormatException` for malformed input and
 * `RegexException` for an invalid pattern; output produced before the
 * error has already been delivered to `sink`.
 */
void processInput(const(char)[] input, scope Sink sink)
{
    enum flushAt = 1 << 16;
    auto reader = LineReader(input);
    char[] out_;
    out_.reserve(flushAt + 4096);
    Match m;

    scope (exit)
        if (out_.length)
            sink(out_);

    immutable patterns = reader.nextInt();
    foreach (_; 0 .. patterns)
    {
        auto pattern = reader.next();
        immutable count = reader.nextInt();
        auto re = new Regex(pattern);
        foreach (__; 0 .. count)
        {
            auto subject = reader.next();
            re.matchInto(subject, m);
            formatMatch(out_, m);
            out_ ~= '\n';
            if (out_.length >= flushAt)
            {
                sink(out_);
                out_.length = 0;
                out_.assumeSafeAppend();
            }
        }
    }
}

/// Convenience wrapper returning the whole output as a string.
string processToString(const(char)[] input)
{
    char[] result;
    processInput(input, (const(char)[] chunk) { result ~= chunk; });
    return cast(string) result;
}

unittest
{
    // Examples 1 and 2 from the specification.
    enum in1 = "3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n^(a+)+$\n2\naaaa\naaab\n";
    assert(processToString(in1) ==
        "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n");

    enum in2 = "2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n2\nzz123xx\nabc9\n";
    assert(processToString(in2) ==
        "match 0 2|1,2|0,1\nmatch 0 2|1,2|1,2\nmatch 1 6\nno\n");
}

unittest
{
    // Example 3, which exercises empty iterations and unset groups.
    enum in3 = "3\n(a*)*b\n2\naab\nccc\nx$|^(y)?z\n3\nxz\nyz\nzzz\n(a){0}b|(c)?(d)\n3\nxb\nxcd\nd\n";
    assert(processToString(in3) ==
        "match 0 3|2,2\nno\nno\nmatch 0 2|0,1\nmatch 0 1|-\n" ~
        "match 1 2|-|-|-\nmatch 1 3|-|1,2|2,3\nmatch 0 1|-|-|0,1\n");
}

unittest
{
    // Positional format: empty and numeric-looking lines, M = 0, spaces.
    assert(processToString("1\n\n0\n") == "");
    assert(processToString("2\n \n2\n\n  \n1\n1\n1\n") == "no\nmatch 0 1\nmatch 0 1\n");
    // The last line may lack a terminator.
    assert(processToString("1\na\n1\nba") == "match 1 2\n");
}

unittest
{
    import std.exception : assertThrown;
    import regex.exception : RegexException;
    assertThrown!BatchFormatException(processToString(""));
    assertThrown!BatchFormatException(processToString("1\na\n2\nx\n"));
    assertThrown!BatchFormatException(processToString("x\n"));
    assertThrown!RegexException(processToString("1\n(\n1\nx\n"));
}

unittest
{
    char[] b;
    putNumber(b, 0);
    b ~= ' ';
    putNumber(b, 1234567890);
    assert(b == "0 1234567890");
}
