/**
 * Command-line front end: reads queries `<a> <op> <b>` from standard input and
 * prints one result line per query (see README.md).
 */
module app.main;

import core.stdc.stdio : stdin, stdout, fread, fwrite;
import std.array : Appender, appender;

import bigint;

/// Reads all of standard input into one buffer.
private ubyte[] readAll()
{
    auto buf = new ubyte[1 << 20];
    size_t len = 0;
    for (;;)
    {
        if (len == buf.length)
            buf.length = buf.length * 2;
        immutable got = fread(buf.ptr + len, 1, buf.length - len, stdin);
        if (got == 0)
            break;
        len += got;
    }
    return buf[0 .. len];
}

/// Evaluates one query and appends its output line (with newline) to `out_`.
private void runQuery(ref Appender!(char[]) out_, const(char)[] ta, const(char)[] op,
        const(char)[] tb)
{
    auto a = BigInt(ta);
    auto b = BigInt(tb);
    switch (op)
    {
    case "+":
        (a + b).writeTo(out_);
        break;
    case "-":
        (a - b).writeTo(out_);
        break;
    case "*":
        (a * b).writeTo(out_);
        break;
    case "/":
    case "%":
        if (b.isZero)
        {
            out_.put("error");
            break;
        }
        BigInt q, r;
        divMod(a, b, q, r);
        (op == "/" ? q : r).writeTo(out_);
        break;
    case "^":
        if (b.isNegative)
        {
            out_.put("error");
            break;
        }
        pow(a, b.toUlong()).writeTo(out_);
        break;
    case "cmp":
        immutable c = a.opCmp(b);
        out_.put(c < 0 ? "-1" : c == 0 ? "0" : "1");
        break;
    default:
        out_.put("error");
        break;
    }
    out_.put('\n');
}

int main()
{
    auto input = cast(const(char)[]) readAll();
    auto out_ = appender!(char[])();
    out_.reserve(1 << 20);

    size_t pos = 0;
    immutable n = input.length;
    while (pos < n)
    {
        // Line is [pos, eol); tokens are separated by single spaces.
        size_t eol = pos;
        while (eol < n && input[eol] != '\n')
            ++eol;
        size_t s1 = pos;
        while (s1 < eol && input[s1] != ' ')
            ++s1;
        size_t s2 = s1 + 1;
        while (s2 < eol && input[s2] != ' ')
            ++s2;
        if (s1 < eol && s2 < eol)
            runQuery(out_, input[pos .. s1], input[s1 + 1 .. s2], input[s2 + 1 .. eol]);
        pos = eol + 1;
    }

    auto data = out_.data;
    if (data.length)
        fwrite(data.ptr, 1, data.length, stdout);
    return 0;
}
