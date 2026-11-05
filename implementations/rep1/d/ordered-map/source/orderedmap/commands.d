/**
 * Interpreter for the line-oriented command language.
 *
 * Input is a count `Q` followed by `Q` command lines; each command produces
 * exactly one output line. See the project README for the command table.
 * Values stored in the map are slices of the input text, so the input must stay
 * alive as long as the map is used.
 */
module orderedmap.commands;

import orderedmap.outbuf;
import orderedmap.parse;
import orderedmap.tree;

/**
 * Executes the whole script in `input` against `map`, appending answers to `output`.
 *
 * Params:
 *   input  = the full text: first line `Q`, then `Q` command lines.
 *   map    = the map to operate on (usually freshly constructed).
 *   output = receives one `\n`-terminated line per command.
 */
void runScript(const(char)[] input, ref OrderedMap map, ref OutBuffer output)
    @trusted
{
    size_t pos = 0;
    skipSpace(input, pos);
    const ulong q = parseULong(input, pos);
    skipLine(input, pos);
    foreach (_; 0 .. q)
    {
        if (pos >= input.length)
            break;
        execute(input, pos, map, output);
    }
}

/// Number of commands announced by the header line of `input`.
size_t commandCount(const(char)[] input) @safe pure nothrow @nogc
{
    size_t pos = 0;
    skipSpace(input, pos);
    return cast(size_t) parseULong(input, pos);
}

private:

void skipSpace(const(char)[] s, ref size_t pos) @safe pure nothrow @nogc
{
    while (pos < s.length && (s[pos] == ' ' || s[pos] == '\r' || s[pos] == '\n'))
        ++pos;
}

/// Moves `pos` to the first byte after the next newline (or to the end).
void skipLine(const(char)[] s, ref size_t pos) @safe pure nothrow @nogc
{
    while (pos < s.length && s[pos] != '\n')
        ++pos;
    if (pos < s.length)
        ++pos;
}

/// Skips the command word and the single space after it.
void skipWord(const(char)[] s, ref size_t pos) @safe pure nothrow @nogc
{
    while (pos < s.length && s[pos] != ' ' && s[pos] != '\n')
        ++pos;
    if (pos < s.length && s[pos] == ' ')
        ++pos;
}

/// Parses one command at `pos`, runs it, and leaves `pos` at the next line.
void execute(const(char)[] s, ref size_t pos, ref OrderedMap map, ref OutBuffer o)
    @trusted
{
    const c0 = s[pos];
    // Second and fourth bytes disambiguate the commands sharing a first byte.
    const c1 = pos + 1 < s.length ? s[pos + 1] : '\0';
    const c3 = pos + 3 < s.length ? s[pos + 3] : '\0';
    skipWord(s, pos);
    long k, k2, res;

    switch (c0)
    {
    case 'i': // insert <key> <value>
        k = parseLong(s, pos);
        ++pos;
        size_t end = pos;
        while (end < s.length && s[end] != '\n')
            ++end;
        size_t vend = end;
        if (vend > pos && s[vend - 1] == '\r')
            --vend;
        o.put(map.insert(k, s[pos .. vend]) ? "ok\n" : "updated\n");
        pos = end;
        break;
    case 'd': // delete <key>
        k = parseLong(s, pos);
        o.put(map.remove(k) ? "ok\n" : "missing\n");
        break;
    case 'g': // get <key>
        k = parseLong(s, pos);
        const(char)[] v;
        if (map.get(k, v))
        {
            o.put(v);
            o.put('\n');
        }
        else
            o.put("missing\n");
        break;
    case 's':
        if (c1 == 'i') // size
        {
            o.put(cast(long) map.length);
            o.put('\n');
        }
        else if (c1 == 'u') // succ
        {
            k = parseLong(s, pos);
            putKeyOrMissing(o, map.succ(k, res), res);
        }
        else // select
        {
            const ulong idx = parseULong(s, pos);
            putKeyOrMissing(o, map.select(idx, res), res);
        }
        break;
    case 'm':
        if (c1 == 'i')
            putKeyOrEmpty(o, map.min(res), res);
        else
            putKeyOrEmpty(o, map.max(res), res);
        break;
    case 'f':
        k = parseLong(s, pos);
        putKeyOrMissing(o, map.floor(k, res), res);
        break;
    case 'c':
        k = parseLong(s, pos);
        putKeyOrMissing(o, map.ceil(k, res), res);
        break;
    case 'p':
        k = parseLong(s, pos);
        putKeyOrMissing(o, map.pred(k, res), res);
        break;
    default: // 'r': range (4th byte 'g') or rank (4th byte 'k')
        if (c3 == 'k')
        {
            k = parseLong(s, pos);
            o.put(cast(long) map.rank(k));
            o.put('\n');
        }
        else
        {
            k = parseLong(s, pos);
            ++pos;
            k2 = parseLong(s, pos);
            RangeWriter w = RangeWriter(&o);
            map.range(k, k2, w);
            o.put(w.any ? "\n" : "empty\n");
        }
        break;
    }
    skipLine(s, pos);
}

struct RangeWriter
{
    OutBuffer* o;
    bool any;

    void put(long key) @trusted
    {
        if (any)
            o.put(' ');
        any = true;
        o.put(key);
    }
}

void putKeyOrMissing(ref OutBuffer o, bool ok, long key) @safe pure nothrow
{
    if (ok)
    {
        o.put(key);
        o.put('\n');
    }
    else
        o.put("missing\n");
}

void putKeyOrEmpty(ref OutBuffer o, bool ok, long key) @safe pure nothrow
{
    if (ok)
    {
        o.put(key);
        o.put('\n');
    }
    else
        o.put("empty\n");
}
