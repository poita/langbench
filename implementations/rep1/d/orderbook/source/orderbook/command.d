/**
 * The textual command language (`LIMIT`, `MARKET`, `CANCEL`, `REPLACE`,
 * `BOOK`): parsing a line into a `Command` and executing it on an
 * `OrderBook`.
 */
module orderbook.command;

import std.range.primitives : isOutputRange;

import orderbook.book : OrderBook;
import orderbook.types;

/// Which command a line holds.
enum CommandKind : ubyte
{
    limit,
    market,
    cancel,
    replace,
    book,
}

/// A parsed command. Fields not used by `kind` are left at their defaults.
struct Command
{
    CommandKind kind;
    string id;
    Side side;
    Price price;
    Qty qty;
    TimeInForce tif;
}

/// Thrown by `processStream` when the input is not well formed.
class ProtocolException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

private string nextToken(ref string s) @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i < s.length && s[i] != ' ')
        i++;
    auto tok = s[0 .. i];
    s = i < s.length ? s[i + 1 .. $] : s[$ .. $];
    return tok;
}

private bool parseNumber(string tok, out long value) @safe pure nothrow @nogc
{
    if (tok.length == 0 || tok.length > 18)
        return false;
    long v = 0;
    foreach (c; tok)
    {
        if (c < '0' || c > '9')
            return false;
        v = v * 10 + (c - '0');
    }
    value = v;
    return true;
}

private bool parseSide(string tok, out Side side) @safe pure nothrow @nogc
{
    if (tok == "BUY")
        side = Side.buy;
    else if (tok == "SELL")
        side = Side.sell;
    else
        return false;
    return true;
}

/**
 * Parse one command line (without its line terminator).
 *
 * Returns: `true` and fills `cmd` on success; `false` if the line is not a
 * well-formed command. Ids in `cmd` are slices of `line`.
 */
bool parseCommand(string line, out Command cmd) @safe pure nothrow @nogc
{
    if (line.length && line[$ - 1] == ' ')
        return false; // trailing space
    string rest = line;
    immutable verb = nextToken(rest);
    long price, qty;
    switch (verb)
    {
    case "LIMIT":
        cmd.kind = CommandKind.limit;
        cmd.id = nextToken(rest);
        if (!parseSide(nextToken(rest), cmd.side)
                || !parseNumber(nextToken(rest), price) || !parseNumber(nextToken(rest), qty))
            return false;
        if (rest.length)
        {
            immutable flag = nextToken(rest);
            if (flag == "IOC")
                cmd.tif = TimeInForce.ioc;
            else if (flag == "FOK")
                cmd.tif = TimeInForce.fok;
            else
                return false;
        }
        break;
    case "MARKET":
        cmd.kind = CommandKind.market;
        cmd.id = nextToken(rest);
        if (!parseSide(nextToken(rest), cmd.side) || !parseNumber(nextToken(rest), qty))
            return false;
        break;
    case "CANCEL":
        cmd.kind = CommandKind.cancel;
        cmd.id = nextToken(rest);
        break;
    case "REPLACE":
        cmd.kind = CommandKind.replace;
        cmd.id = nextToken(rest);
        if (!parseNumber(nextToken(rest), price) || !parseNumber(nextToken(rest), qty))
            return false;
        break;
    case "BOOK":
        cmd.kind = CommandKind.book;
        break;
    default:
        return false;
    }
    if (rest.length || cmd.kind != CommandKind.book && cmd.id.length == 0)
        return false;
    if (cmd.kind != CommandKind.cancel && cmd.kind != CommandKind.book && (qty < 1 || qty > uint.max))
        return false;
    if ((cmd.kind == CommandKind.limit || cmd.kind == CommandKind.replace)
            && (price < 1 || price > uint.max))
        return false;
    cmd.price = cast(Price) price;
    cmd.qty = qty;
    return true;
}

/// Execute `cmd` on `book`, sending the resulting events to `sink`.
void execute(Sink)(OrderBook book, in Command cmd, ref Sink sink)
        if (isOutputRange!(Sink, Event))
{
    final switch (cmd.kind)
    {
    case CommandKind.limit:
        book.limit(cmd.id, cmd.side, cmd.price, cmd.qty, cmd.tif, sink);
        break;
    case CommandKind.market:
        book.market(cmd.id, cmd.side, cmd.qty, sink);
        break;
    case CommandKind.cancel:
        book.cancel(cmd.id, sink);
        break;
    case CommandKind.replace:
        book.replace(cmd.id, cmd.price, cmd.qty, sink);
        break;
    case CommandKind.book:
        book.snapshot(sink);
        break;
    }
}

/**
 * Run a whole input stream: a count `N` on the first line, then `N` command
 * lines (the last newline is optional). Events go to `sink`.
 *
 * Throws: `ProtocolException` on a malformed or missing line.
 */
void processStream(Sink)(OrderBook book, string input, ref Sink sink)
        if (isOutputRange!(Sink, Event))
{
    string rest = input;
    long n;
    if (!parseNumber(nextLine(rest), n))
        throw new ProtocolException("first line must be the command count");
    foreach (i; 0 .. n)
    {
        if (rest.length == 0)
            throw new ProtocolException("fewer command lines than announced");
        Command cmd;
        if (!parseCommand(nextLine(rest), cmd))
            throw new ProtocolException("malformed command");
        execute(book, cmd, sink);
    }
}

private string nextLine(ref string s) @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i < s.length && s[i] != '\n')
        i++;
    auto line = s[0 .. i];
    s = i < s.length ? s[i + 1 .. $] : s[$ .. $];
    return line;
}

unittest
{
    Command c;
    assert(parseCommand("LIMIT a1 BUY 100 5", c));
    assert(c.kind == CommandKind.limit && c.id == "a1" && c.side == Side.buy
            && c.price == 100 && c.qty == 5 && c.tif == TimeInForce.gtc);
    assert(parseCommand("LIMIT BUY SELL 7 2 FOK", c));
    assert(c.id == "BUY" && c.side == Side.sell && c.tif == TimeInForce.fok);
    assert(parseCommand("MARKET m SELL 3", c) && c.kind == CommandKind.market);
    assert(parseCommand("CANCEL BOOK", c) && c.id == "BOOK");
    assert(parseCommand("REPLACE x 4 1000000000", c) && c.qty == 1_000_000_000);
    assert(parseCommand("BOOK", c) && c.kind == CommandKind.book);
    assert(!parseCommand("", c));
    assert(!parseCommand("LIMIT a BUY 1", c));
    assert(!parseCommand("LIMIT a BUY 1 1 GTC", c));
    assert(!parseCommand("LIMIT a BUY 1 1 ", c));
    assert(!parseCommand("LIMIT a BUY 0 1", c));
    assert(!parseCommand("NOPE", c));
    assert(!parseCommand("BOOK extra", c));
}

unittest
{
    import std.array : appender;
    import orderbook.format : textSink;

    auto w = appender!string;
    auto sink = textSink(w);
    processStream(new OrderBook, "3\nLIMIT a BUY 5 2\nBOOK\nCANCEL a", sink);
    assert(w[] == "REST a\nBID 5 2 1\n--\nCANCEL a 2\n");

    auto w2 = appender!string;
    auto sink2 = textSink(w2);
    processStream(new OrderBook, "0\n", sink2);
    assert(w2[] == "");

    import std.exception : assertThrown;

    assertThrown!ProtocolException(processStream(new OrderBook, "2\nBOOK\n", sink2));
    assertThrown!ProtocolException(processStream(new OrderBook, "1\nWHAT\n", sink2));
}
