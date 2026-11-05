/// Command-line front end: reads queries from stdin, writes symbols to stdout.
module app.main;

import core.stdc.stdlib : exit;
import std.array : appender;
import std.stdio : stderr, stdin, stdout;

import qrcode;

private ubyte[] readAllStdin()
{
    auto buf = appender!(ubyte[])();
    ubyte[1 << 16] chunk;
    for (;;)
    {
        auto got = stdin.rawRead(chunk[]);
        if (got.length == 0)
            break;
        buf.put(got);
    }
    return buf.data;
}

private int fail(string msg)
{
    stderr.writeln("qrcode: ", msg);
    return 1;
}

int main()
{
    auto input = readAllStdin();
    auto output = appender!(char[])();
    output.reserve(1 << 20);

    size_t pos = 0;
    size_t lineNo = 0;
    while (pos < input.length)
    {
        size_t end = pos;
        while (end < input.length && input[end] != '\n')
            ++end;
        auto line = input[pos .. end];
        pos = end + 1;
        ++lineNo;
        if (line.length && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];
        if (line.length == 0)
            continue;

        // <ecl> <mask> <text>
        if (line.length < 5 || line[1] != ' ')
            return fail("malformed query on line " ~ itoa(lineNo));
        Ecl ecl;
        switch (line[0])
        {
        case 'L': ecl = Ecl.L; break;
        case 'M': ecl = Ecl.M; break;
        case 'Q': ecl = Ecl.Q; break;
        case 'H': ecl = Ecl.H; break;
        default: return fail("bad error correction level on line " ~ itoa(lineNo));
        }
        size_t sp = 2;
        while (sp < line.length && line[sp] != ' ')
            ++sp;
        if (sp >= line.length - 1)
            return fail("malformed query on line " ~ itoa(lineNo));
        const maskTok = line[2 .. sp];
        int mask;
        if (maskTok.length == 1 && maskTok[0] >= '0' && maskTok[0] <= '7')
            mask = maskTok[0] - '0';
        else if (maskTok == cast(const(ubyte)[]) "auto")
            mask = autoMask;
        else
            return fail("bad mask on line " ~ itoa(lineNo));

        try
        {
            encode(line[sp + 1 .. $], ecl, mask).writeText(output);
        }
        catch (QrException e)
        {
            return fail("line " ~ itoa(lineNo) ~ ": " ~ e.msg);
        }
    }

    stdout.rawWrite(output.data);
    stdout.flush();
    return 0;
}

private string itoa(size_t n)
{
    import std.conv : to;

    return n.to!string;
}
