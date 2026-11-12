/**
 * The line-oriented command protocol: parses commands such as
 * `insert 5 five` or `range 2 9`, applies them to an $(REF OrderedMap,
 * orderedmap,tree) and writes one reply line per command.
 *
 * See the project README for the full command list.
 */
module orderedmap.commands;

import orderedmap.numbers;
import orderedmap.tree;

import std.typecons : Nullable;

/// Thrown for an unknown command or a malformed argument list.
class CommandException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// The map type driven by the command protocol: `long` keys, `string` values.
alias Map = OrderedMap!(long, string);

/**
 * Executes protocol commands against a map and appends the replies to an
 * output range.
 */
struct Interpreter
{
    /// The map being operated on.
    Map map;

    /**
     * Executes one command line (without its line terminator) and writes the
     * reply, including a trailing `'\n'`, to `sink`.
     *
     * Values are stored as slices of `line`, so `line` must outlive the map
     * contents (it is `immutable`, so the garbage collector keeps it alive).
     *
     * Params:
     *     line = one command, tokens separated by single spaces
     *     sink = an output range accepting `const(char)[]`, e.g. `Appender!(char[])`
     *
     * Throws: `CommandException` or `NumberFormatException` for bad input.
     */
    void execute(Sink)(string line, ref Sink sink)
    {
        string rest = line;
        immutable cmd = nextToken(rest);
        switch (cmd)
        {
        case "insert":
            immutable key = parseLong(nextToken(rest));
            immutable value = nextToken(rest);
            if (value.length == 0)
                throw new CommandException("insert: missing value");
            reply(sink, map.insert(key, value) ? "ok" : "updated");
            break;
        case "delete":
            reply(sink, map.remove(parseLong(nextToken(rest))) ? "ok" : "missing");
            break;
        case "get":
            if (auto p = parseLong(nextToken(rest)) in map)
                reply(sink, *p);
            else
                reply(sink, "missing");
            break;
        case "size":
            replyUlong(sink, map.length);
            break;
        case "min":
            replyKey(sink, map.minKey, "empty");
            break;
        case "max":
            replyKey(sink, map.maxKey, "empty");
            break;
        case "floor":
            replyKey(sink, map.floor(parseLong(nextToken(rest))), "missing");
            break;
        case "ceil":
            replyKey(sink, map.ceil(parseLong(nextToken(rest))), "missing");
            break;
        case "succ":
            replyKey(sink, map.successor(parseLong(nextToken(rest))), "missing");
            break;
        case "pred":
            replyKey(sink, map.predecessor(parseLong(nextToken(rest))), "missing");
            break;
        case "rank":
            replyUlong(sink, map.rank(parseLong(nextToken(rest))));
            break;
        case "select":
            immutable k = parseUlong(nextToken(rest));
            replyKey(sink, k > size_t.max ? Nullable!long.init : map.select(cast(size_t) k), "missing");
            break;
        case "range":
            immutable lo = parseLong(nextToken(rest));
            immutable hi = parseLong(nextToken(rest));
            bool first = true;
            map.forEachInRange(lo, hi, (long k, string v) {
                if (!first)
                    sink.put(" ");
                first = false;
                putLong(sink, k);
            });
            if (first)
                sink.put("empty");
            sink.put("\n");
            break;
        default:
            throw new CommandException("unknown command: " ~ cmd);
        }
        if (rest.length)
            throw new CommandException("trailing garbage after command: " ~ cmd);
    }

    /**
     * Runs a whole script: the first line is the command count `Q`, followed by
     * up to `Q` command lines. Output for each command is appended to `sink`.
     *
     * Lines may end in `\n` or `\r\n`; the final newline is optional. Anything
     * after the `Q`-th command is ignored.
     */
    void run(Sink)(string input, ref Sink sink)
    {
        string rest = input;
        immutable header = nextLine(rest);
        immutable q = parseUlong(header);
        foreach (_; 0 .. q)
        {
            if (rest.length == 0)
                break;
            execute(nextLine(rest), sink);
        }
    }
}

private:

/// Splits off the next space-delimited token of `s`, advancing `s` past it and the separator.
string nextToken(ref string s) @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i < s.length && s[i] != ' ')
        ++i;
    auto tok = s[0 .. i];
    s = i < s.length ? s[i + 1 .. $] : s[$ .. $];
    return tok;
}

/// Splits off the next line of `s` without its terminator (`\n` or `\r\n`).
string nextLine(ref string s) @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i < s.length && s[i] != '\n')
        ++i;
    auto line = s[0 .. i];
    s = i < s.length ? s[i + 1 .. $] : s[$ .. $];
    if (line.length && line[$ - 1] == '\r')
        line = line[0 .. $ - 1];
    return line;
}

void reply(Sink)(ref Sink sink, const(char)[] text)
{
    sink.put(text);
    sink.put("\n");
}

void putLong(Sink)(ref Sink sink, long v)
{
    char[maxLongChars] buf = void;
    sink.put(formatLong(buf, v));
}

void replyUlong(Sink)(ref Sink sink, ulong v)
{
    putLong(sink, cast(long) v); // counts never exceed long.max
    sink.put("\n");
}

void replyKey(Sink)(ref Sink sink, Nullable!long key, string whenNull)
{
    if (key.isNull)
        sink.put(whenNull);
    else
        putLong(sink, key.get);
    sink.put("\n");
}

version (unittest)
{
    import std.array : appender;

    string runScript(string input)
    {
        Interpreter it;
        auto o = appender!string;
        it.run(input, o);
        return o[];
    }
}

@("worked example 1")
unittest
{
    immutable input = "12\nsize\nmin\ninsert 5 five\ninsert 5 FIVE\nget 5\ninsert 2 two\n"
        ~ "insert 9 nine\nmin\nmax\nrange 2 9\ndelete 5\nrange 3 8";
    assert(runScript(input) == "0\nempty\nok\nupdated\nFIVE\nok\nok\n2\n9\n2 5 9\nok\nempty\n");
}

@("worked example 2")
unittest
{
    immutable input = "14\ninsert 10 a\ninsert 20 b\ninsert 30 c\nfloor 25\nceil 25\nfloor 10\n"
        ~ "ceil 10\nsucc 10\npred 10\nsucc 30\nrank 20\nrank 21\nselect 2\nselect 3\n";
    assert(runScript(input) == "ok\nok\nok\n20\n30\n10\n10\n20\nmissing\nmissing\n1\n2\n30\nmissing\n");
}

@("worked example 3: extreme keys")
unittest
{
    immutable input = "9\ninsert -9223372036854775808 lo\ninsert 9223372036854775807 hi\ninsert 0 zero\n"
        ~ "succ 9223372036854775807\npred -9223372036854775808\nfloor -9223372036854775807\nceil 1\n"
        ~ "range -9223372036854775808 9223372036854775807\ndelete 0\n";
    assert(runScript(input) == "ok\nok\nok\nmissing\nmissing\n-9223372036854775808\n"
            ~ "9223372036854775807\n-9223372036854775808 0 9223372036854775807\nok\n");
}

@("empty input and CRLF")
unittest
{
    assert(runScript("0\n") == "");
    assert(runScript("0") == "");
    assert(runScript("2\r\ninsert 1 a\r\nget 1\r\n") == "ok\na\n");
}

@("values are opaque")
unittest
{
    assert(runScript("5\ninsert 1 missing\nget 1\ninsert 2 \"'`\\<>|{}#\nget 2\nsize\n")
            == "ok\nmissing\nok\n\"'`\\<>|{}#\n2\n");
}

@("queries on an empty map")
unittest
{
    assert(runScript("9\nmin\nmax\nfloor 1\nceil 1\nsucc 1\npred 1\nrank 1\nselect 0\nrange 1 5\n")
            == "empty\nempty\nmissing\nmissing\nmissing\nmissing\n0\nmissing\nempty\n");
}

@("range with lo > hi and select beyond range")
unittest
{
    assert(runScript("4\ninsert 1 a\nrange 5 1\nselect 1000000000\nrange 1 1\n") == "ok\nempty\nmissing\n1\n");
}

@("bad input is rejected")
unittest
{
    import std.exception : assertThrown;

    assertThrown!CommandException(runScript("1\nfrobnicate 1\n"));
    assertThrown!CommandException(runScript("1\ninsert 1\n"));
    assertThrown!CommandException(runScript("1\nsize extra\n"));
    assertThrown!NumberFormatException(runScript("1\nget abc\n"));
    assertThrown!NumberFormatException(runScript("x\n"));
}
