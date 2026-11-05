/**
 * The line-oriented batch protocol: many patterns, each with many subjects.
 *
 * Input: `N`, then for each pattern the pattern line, a count `M`, and `M`
 * subject lines. Output: one line per subject, `no` or
 * `match <start> <end>` followed by `|<gs>,<ge>` / `|-` for each group.
 */
module regex.batch;

import core.stdc.string : memchr;

import regex.compiler;
import regex.parser : RegexException;
import regex.program;
import regex.vm;

/// Thrown when the batch input is malformed.
class BatchFormatException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// A growing byte buffer with fast decimal output.
struct OutputBuffer
{
    ubyte[] data;
    size_t length;

    private void reserve(size_t extra) @safe
    {
        if (length + extra > data.length)
        {
            size_t cap = data.length < 4096 ? 4096 : data.length;
            while (cap < length + extra)
                cap *= 2;
            data.length = cap;
        }
    }

    /// Appends one byte.
    void put(ubyte b) @safe
    {
        reserve(1);
        data[length++] = b;
    }

    /// Appends text.
    void put(const(char)[] s) @safe
    {
        reserve(s.length);
        foreach (c; s)
            data[length++] = cast(ubyte) c;
    }

    /// Appends a non-negative integer in decimal.
    void putInt(uint v) @safe
    {
        reserve(10);
        ubyte[10] tmp;
        size_t k = 0;
        do
        {
            tmp[k++] = cast(ubyte)('0' + v % 10);
            v /= 10;
        }
        while (v != 0);
        while (k > 0)
            data[length++] = tmp[--k];
    }

    /// The bytes written so far.
    const(ubyte)[] bytes() const pure nothrow @nogc @safe { return data[0 .. length]; }
}

/// Sequential reader of `\n`-terminated lines (views into the input, no copying).
struct LineReader
{
    const(ubyte)[] input;
    size_t pos;

    /// Next line without its terminator. Throws at end of input.
    const(ubyte)[] next() @trusted
    {
        if (pos >= input.length)
            throw new BatchFormatException("unexpected end of input");
        const rest = input[pos .. $];
        const p = cast(const(ubyte)*) memchr(rest.ptr, '\n', rest.length);
        size_t len = p is null ? rest.length : p - rest.ptr;
        auto line = rest[0 .. len];
        pos += len + (p is null ? 0 : 1);
        return line;
    }

    /// Reads a line holding a plain decimal count.
    size_t nextCount()
    {
        const line = next();
        if (line.length == 0 || line.length > 12)
            throw new BatchFormatException("expected a count");
        size_t v = 0;
        foreach (c; line)
        {
            if (c < '0' || c > '9')
                throw new BatchFormatException("expected a count");
            v = v * 10 + (c - '0');
        }
        return v;
    }
}

/// Appends the result line for the last search of `matcher` to `output`.
void formatResult(ref OutputBuffer output, bool matched, const Matcher matcher) @safe
{
    if (!matched)
    {
        output.put("no\n");
        return;
    }
    output.put("match ");
    output.putInt(matcher.matchStart);
    output.put(' ');
    output.putInt(matcher.matchEnd);
    const caps = matcher.captures;
    for (size_t g = 0; g < caps.length; g += 2)
    {
        output.put('|');
        if (caps[g] < 0)
            output.put('-');
        else
        {
            output.putInt(caps[g]);
            output.put(',');
            output.putInt(caps[g + 1]);
        }
    }
    output.put('\n');
}

/**
 * Processes a whole batch `input`, appending all result lines to `output`.
 *
 * Throws: `BatchFormatException` for malformed input, `RegexException` for an invalid pattern.
 */
void processBatch(const(ubyte)[] input, ref OutputBuffer output) @trusted
{
    auto reader = LineReader(input);
    const patterns = reader.nextCount();
    scope matcher = new Matcher;
    foreach (_; 0 .. patterns)
    {
        const pattern = cast(const(char)[]) reader.next();
        const count = reader.nextCount();
        if (count == 0)
            continue;
        const prog = compile(pattern);
        foreach (__; 0 .. count)
        {
            const subject = cast(const(char)[]) reader.next();
            const matched = matcher.search(prog, subject);
            formatResult(output, matched, matcher);
        }
    }
}
