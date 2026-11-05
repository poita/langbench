/++
Single-pass, allocation-light parser for the command stream.

The whole input is walked once with an index. Order ids are not copied: each
`Command` stores the offset and length of its id within the input buffer.
+/
module orderbook.parser;

import orderbook.types;

/// Result of parsing: the commands and every price named by LIMIT/REPLACE.
struct ParseResult
{
    /// Commands in input order (ranks not yet assigned).
    Command[] commands;
    /// All prices of LIMIT and REPLACE commands, in input order, with duplicates.
    uint[] prices;
}

/++
Parse a command stream: a count line `N` followed by up to `N` command lines.

The input is assumed well formed (see SPEC.md); a missing trailing newline is
fine, and parsing stops quietly if the input ends before `N` commands.
+/
ParseResult parseCommands(scope const(char)[] input) @trusted pure nothrow
{
    ParseResult res;
    const n = input.length;
    size_t p = 0;

    ulong readNum()
    {
        ulong v = 0;
        while (p < n && input[p] >= '0' && input[p] <= '9')
            v = v * 10 + (input[p++] - '0');
        return v;
    }
    void skipToken()
    {
        while (p < n && input[p] != ' ' && input[p] != '\n')
            ++p;
    }
    // Skip the single separator space, if any.
    void skipSpace()
    {
        if (p < n && input[p] == ' ')
            ++p;
    }
    void readId(ref Command c)
    {
        const start = p;
        skipToken();
        c.idOff = cast(uint) start;
        c.idLen = cast(ubyte)(p - start);
        skipSpace();
    }
    Side readSide()
    {
        const s = input[p] == 'B' ? Side.buy : Side.sell;
        skipToken();
        skipSpace();
        return s;
    }

    while (p < n && (input[p] == ' ' || input[p] == '\n'))
        ++p;
    const count = readNum();
    res.commands.reserve(cast(size_t)(count < n ? count : n));

    foreach (_; 0 .. count)
    {
        while (p < n && input[p] == '\n')
            ++p;
        if (p >= n)
            break;
        Command c;
        const kw = input[p];
        skipToken();
        skipSpace();
        switch (kw)
        {
        case 'L':
            c.kind = CmdKind.limit;
            readId(c);
            c.side = readSide();
            c.price = cast(uint) readNum();
            skipSpace();
            c.qty = cast(uint) readNum();
            if (p < n && input[p] == ' ')
            {
                ++p;
                c.tif = input[p] == 'I' ? Tif.ioc : Tif.fok;
                skipToken();
            }
            res.prices ~= c.price;
            break;
        case 'M':
            c.kind = CmdKind.market;
            readId(c);
            c.side = readSide();
            c.qty = cast(uint) readNum();
            break;
        case 'C':
            c.kind = CmdKind.cancel;
            readId(c);
            break;
        case 'R':
            c.kind = CmdKind.replace;
            readId(c);
            c.price = cast(uint) readNum();
            skipSpace();
            c.qty = cast(uint) readNum();
            res.prices ~= c.price;
            break;
        default:
            c.kind = CmdKind.book;
            break;
        }
        res.commands ~= c;
    }
    return res;
}
