/// Canonical TOML writer.
module toml.encoder;

import std.algorithm.sorting : sort;
import std.array : Appender, appender;
import toml.node;

/**
 * Renders a table tree as a canonical TOML document.
 *
 * Within each table, plain pairs come first in ascending key order, followed
 * by sub-tables and arrays of tables (each with a header). Every table gets
 * a header, empty ones included. The output ends with a single newline.
 * Scalars are written from their canonical text, so
 * `parseToml(toToml(x))` reproduces `x`.
 */
string toToml(Node root)
{
    auto o = appender!(char[]);
    o.reserve(4096);
    writeTable(o, root, "");
    if (o.data.length == 0) o.put('\n');
    return cast(string) o.data;
}

private:

/// An array that is rendered as `[[header]]` sections.
bool isArrayOfTables(Node n)
{
    if (n.kind != Kind.array || n.elements.length == 0) return false;
    foreach (e; n.elements)
        if (e.kind != Kind.table) return false;
    return true;
}

void writeTable(ref Appender!(char[]) o, Node t, string path)
{
    auto keys = t.members.keys;
    keys.sort();
    foreach (k; keys)
    {
        auto v = t.members[k];
        if (v.kind == Kind.table || isArrayOfTables(v)) continue;
        writeKey(o, k);
        o.put(" = ");
        writeInline(o, v);
        o.put('\n');
    }
    foreach (k; keys)
    {
        auto v = t.members[k];
        string sub = null;
        if (v.kind == Kind.table)
        {
            sub = joinPath(path, k);
            if (o.data.length) o.put('\n');
            o.put('[');
            o.put(sub);
            o.put("]\n");
            writeTable(o, v, sub);
        }
        else if (isArrayOfTables(v))
        {
            sub = joinPath(path, k);
            foreach (e; v.elements)
            {
                if (o.data.length) o.put('\n');
                o.put("[[");
                o.put(sub);
                o.put("]]\n");
                writeTable(o, e, sub);
            }
        }
    }
}

string joinPath(string path, string key)
{
    auto b = appender!(char[]);
    b.put(path);
    if (path.length) b.put('.');
    writeKey(b, key);
    return cast(string) b.data;
}

void writeInline(ref Appender!(char[]) o, Node v)
{
    final switch (v.kind)
    {
    case Kind.string_:
        writeBasicString(o, v.text);
        break;
    case Kind.integer, Kind.float_, Kind.boolean, Kind.offsetDateTime,
         Kind.localDateTime, Kind.localDate, Kind.localTime:
        o.put(v.text);
        break;
    case Kind.array:
        o.put('[');
        foreach (i, e; v.elements)
        {
            if (i) o.put(", ");
            writeInline(o, e);
        }
        o.put(']');
        break;
    case Kind.table:
        o.put('{');
        auto keys = v.members.keys;
        keys.sort();
        foreach (i, k; keys)
        {
            if (i) o.put(", ");
            writeKey(o, k);
            o.put(" = ");
            writeInline(o, v.members[k]);
        }
        o.put('}');
        break;
    }
}

bool isBare(const(char)[] k)
{
    if (k.length == 0) return false;
    foreach (c; k)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'))
            return false;
    return true;
}

void writeKey(ref Appender!(char[]) o, const(char)[] k)
{
    if (isBare(k)) o.put(k);
    else writeBasicString(o, k);
}

void writeBasicString(ref Appender!(char[]) o, const(char)[] s)
{
    static immutable hexDigits = "0123456789abcdef";
    o.put('"');
    size_t run = 0;
    foreach (i, c; s)
    {
        if (c >= 0x20 && c != '"' && c != '\\' && c != 0x7F) continue;
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
            o.put(hexDigits[c >> 4]);
            o.put(hexDigits[c & 15]);
        }
    }
    o.put(s[run .. $]);
    o.put('"');
}
