/++
    The batch protocol used by the command-line tool: a block of input
    holding patterns and subject lines, answered with one result line per
    subject. See the README for the exact format.
+/
module regex.batch;

import core.stdc.string : memchr;

import regex.compiler;
import regex.exception;
import regex.parser;
import regex.program;
import regex.vm;

/// A growable byte buffer with integer formatting.
struct OutputBuffer
{
    ubyte[] data;
    size_t length;

    private void reserve(size_t extra) @trusted
    {
        if (length + extra > data.length)
        {
            size_t cap = data.length ? data.length : 4096;
            while (cap < length + extra)
                cap *= 2;
            data.length = cap;
        }
    }

    /// Append raw text.
    void put(const(char)[] s) @trusted
    {
        reserve(s.length);
        data[length .. length + s.length] = cast(const(ubyte)[]) s;
        length += s.length;
    }

    /// Append one byte.
    void put(char c) @trusted
    {
        reserve(1);
        data[length++] = c;
    }

    /// Append a non-negative integer in decimal.
    void putInt(uint v) @trusted
    {
        reserve(10);
        ubyte[10] tmp = void;
        size_t i = tmp.length;
        do
        {
            tmp[--i] = cast(ubyte)('0' + v % 10);
            v /= 10;
        }
        while (v != 0);
        const len = tmp.length - i;
        data[length .. length + len] = tmp[i .. $];
        length += len;
    }

    /// The bytes written so far.
    const(ubyte)[] bytes() const @safe pure nothrow @nogc
    {
        return data[0 .. length];
    }
}

/// Appends the result line for the last successful or failed search of `matcher`.
void formatResult(ref OutputBuffer o, bool matched, ref const Matcher matcher, int groupCount) @safe
{
    if (!matched)
    {
        o.put("no\n");
        return;
    }
    o.put("match ");
    o.putInt(matcher.matchStart);
    o.put(' ');
    o.putInt(matcher.matchEnd);
    foreach (g; 1 .. groupCount + 1)
    {
        o.put('|');
        const s = matcher.groupStart(g);
        if (s < 0)
            o.put('-');
        else
        {
            o.putInt(s);
            o.put(',');
            o.putInt(matcher.groupEnd(g));
        }
    }
    o.put('\n');
}

/++
    Process a whole batch `input` and append the results to `output`.
    Lines are consumed strictly by position; patterns and subjects are views
    into `input` and are never copied. Throws `RegexException` for an invalid
    pattern.
+/
void processBatch(const(ubyte)[] input, ref OutputBuffer output) @trusted
{
    size_t pos = 0;

    // Returns the next line as a view (without its '\n') and advances.
    const(ubyte)[] nextLine()
    {
        if (pos >= input.length)
            return null;
        const rest = input.length - pos;
        const p = cast(const(ubyte)*) memchr(input.ptr + pos, '\n', rest);
        const end = p is null ? input.length : cast(size_t)(p - input.ptr);
        auto line = input[pos .. end];
        pos = end + 1;
        return line;
    }

    static size_t parseCount(const(ubyte)[] line)
    {
        size_t v = 0;
        foreach (c; line)
        {
            if (c < '0' || c > '9')
                break;
            v = v * 10 + (c - '0');
        }
        return v;
    }

    const patterns = parseCount(nextLine());
    Matcher matcher;
    foreach (_; 0 .. patterns)
    {
        const pattern = nextLine();
        const subjects = parseCount(nextLine());
        auto prog = compile(parse(cast(const(char)[]) pattern));
        foreach (__; 0 .. subjects)
        {
            const subject = nextLine();
            const matched = matcher.search(prog, subject);
            formatResult(output, matched, matcher, prog.groupCount);
        }
    }
}
