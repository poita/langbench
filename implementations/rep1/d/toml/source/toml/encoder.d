/**
 * The canonical TOML writer: renders a tree as the deterministic document
 * described in SPEC.md §2.2 (pairs first, then sub-tables and arrays of
 * tables, each level in code-point key order).
 */
module toml.encoder;

import std.array : Appender, appender;
import toml.node;

/// Renders `root` (a table) as canonical TOML. The result ends with `\n`.
string toToml(Node root)
{
    if (!root.isTable)
        throw new TomlException("the root must be a table");
    auto o = appender!(char[])();
    writeTable(o, root, "");
    if (o.data.length == 0)
        o.put('\n');
    return cast(string) o.data;
}

/// Renders a key: bare when possible, otherwise a quoted basic string.
string renderKey(string k)
{
    bool bare = k.length > 0;
    foreach (c; k)
        if (!isBare(c))
        {
            bare = false;
            break;
        }
    if (bare)
        return k;
    auto o = appender!(char[])();
    quote(o, k);
    return cast(string) o.data;
}

private bool isBare(char c) pure nothrow @safe @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '_' || c == '-';
}

private void quote(ref Appender!(char[]) o, string s)
{
    static immutable hexd = "0123456789abcdef";
    o.put('"');
    size_t run = 0;
    foreach (i, c; s)
    {
        if (c >= 0x20 && c != '"' && c != '\\' && c != 0x7f)
            continue;
        o.put(s[run .. i]);
        run = i + 1;
        switch (c)
        {
        case '"':  o.put(`\"`); break;
        case '\\': o.put(`\\`); break;
        case '\b': o.put(`\b`); break;
        case '\t': o.put(`\t`); break;
        case '\n': o.put(`\n`); break;
        case '\f': o.put(`\f`); break;
        case '\r': o.put(`\r`); break;
        default:
            o.put(`\u00`);
            o.put(hexd[c >> 4]);
            o.put(hexd[c & 15]);
        }
    }
    o.put(s[run .. $]);
    o.put('"');
}

private bool isArrayOfTables(Node n) pure nothrow @safe
{
    if (n.kind != Kind.array || n.items.length == 0)
        return false;
    foreach (e; n.items)
        if (e.kind != Kind.table)
            return false;
    return true;
}

private void writeInline(ref Appender!(char[]) o, Node n)
{
    final switch (n.kind)
    {
    case Kind.table:
        o.put('{');
        bool first = true;
        foreach (k; n.sortedKeys)
        {
            if (!first) o.put(", ");
            first = false;
            o.put(renderKey(k));
            o.put(" = ");
            writeInline(o, n.fields[k]);
        }
        o.put('}');
        break;
    case Kind.array:
        o.put('[');
        foreach (i, e; n.items)
        {
            if (i) o.put(", ");
            writeInline(o, e);
        }
        o.put(']');
        break;
    case Kind.string:
        quote(o, n.text);
        break;
    case Kind.integer, Kind.float_, Kind.boolean, Kind.datetime,
         Kind.datetimeLocal, Kind.dateLocal, Kind.timeLocal:
        o.put(n.text);
        break;
    }
}

private void writeTable(ref Appender!(char[]) o, Node t, string path)
{
    auto keys = t.sortedKeys;
    foreach (k; keys)
    {
        auto v = t.fields[k];
        if (v.kind == Kind.table || isArrayOfTables(v))
            continue;
        o.put(renderKey(k));
        o.put(" = ");
        writeInline(o, v);
        o.put('\n');
    }
    foreach (k; keys)
    {
        auto v = t.fields[k];
        immutable sub = path.length ? path ~ "." ~ renderKey(k) : renderKey(k);
        if (v.kind == Kind.table)
        {
            header(o, sub, false);
            writeTable(o, v, sub);
        }
        else if (isArrayOfTables(v))
        {
            foreach (e; v.items)
            {
                header(o, sub, true);
                writeTable(o, e, sub);
            }
        }
    }
}

private void header(ref Appender!(char[]) o, string path, bool array)
{
    if (o.data.length)
        o.put('\n');
    o.put(array ? "[[" : "[");
    o.put(path);
    o.put(array ? "]]\n" : "]\n");
}
