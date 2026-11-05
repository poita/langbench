/// Renders a `Node` tree as canonical TOML.
module toml.encoder;

import std.array : Appender, appender;
import std.algorithm.sorting : sort;
import toml.node;

/**
 * Renders `root` (a table) as the canonical TOML document described in the
 * README: scalar pairs first in key order, then sub-tables and arrays of
 * tables with explicit headers, each preceded by a blank line unless it is
 * the first line of the document.
 */
string toToml(Node root)
{
    auto app = appender!(char[]);
    app.reserve(4096);
    renderTable(app, root, "");
    if (app.data.length == 0)
        app.put('\n');
    return cast(string) app.data;
}

private:

enum Class : ubyte { inlineValue, subTable, tableArray }

Class classify(Node n)
{
    if (n.kind == Kind.table)
        return Class.subTable;
    if (n.kind == Kind.array && n.items.length > 0)
    {
        foreach (e; n.items)
            if (e.kind != Kind.table)
                return Class.inlineValue;
        return Class.tableArray;
    }
    return Class.inlineValue;
}

void renderTable(ref Appender!(char[]) o, Node t, string path)
{
    auto keys = t.members.keys;
    keys.sort();
    auto classes = new Class[keys.length];
    bool anyHeader = false;
    foreach (i, k; keys)
    {
        auto c = classify(t.members[k]);
        classes[i] = c;
        if (c == Class.inlineValue)
        {
            writeKey(o, k);
            o.put(" = ");
            writeInline(o, t.members[k]);
            o.put('\n');
        }
        else
            anyHeader = true;
    }
    if (!anyHeader)
        return;
    foreach (i, k; keys)
    {
        immutable c = classes[i];
        if (c == Class.inlineValue)
            continue;
        auto child = t.members[k];
        auto childPath = path.length ? path ~ "." ~ renderKey(k) : renderKey(k);
        if (c == Class.subTable)
        {
            header(o, childPath, false);
            renderTable(o, child, childPath);
        }
        else
        {
            foreach (e; child.items)
            {
                header(o, childPath, true);
                renderTable(o, e, childPath);
            }
        }
    }
}

void header(ref Appender!(char[]) o, string path, bool array)
{
    if (o.data.length != 0)
        o.put('\n');
    o.put(array ? "[[" : "[");
    o.put(path);
    o.put(array ? "]]\n" : "]\n");
}

void writeInline(ref Appender!(char[]) o, Node n)
{
    switch (n.kind)
    {
    case Kind.table:
        o.put('{');
        auto keys = n.members.keys;
        keys.sort();
        foreach (i, k; keys)
        {
            if (i)
                o.put(", ");
            writeKey(o, k);
            o.put(" = ");
            writeInline(o, n.members[k]);
        }
        o.put('}');
        break;
    case Kind.array:
        o.put('[');
        foreach (i, e; n.items)
        {
            if (i)
                o.put(", ");
            writeInline(o, e);
        }
        o.put(']');
        break;
    case Kind.string_:
        writeBasicString(o, n.text);
        break;
    default:
        o.put(n.text);
    }
}

bool isBareKey(const(char)[] k) pure nothrow @nogc
{
    if (k.length == 0)
        return false;
    foreach (c; k)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'))
            return false;
    return true;
}

void writeKey(ref Appender!(char[]) o, const(char)[] k)
{
    if (isBareKey(k))
        o.put(k);
    else
        writeBasicString(o, k);
}

string renderKey(const(char)[] k)
{
    if (isBareKey(k))
        return k.idup;
    auto a = appender!(char[]);
    writeBasicString(a, k);
    return cast(string) a.data;
}

/// Writes a TOML basic string, escaping only what must be escaped.
void writeBasicString(ref Appender!(char[]) o, const(char)[] s)
{
    static immutable hexd = "0123456789abcdef";
    o.put('"');
    size_t start = 0;
    foreach (i, c; s)
    {
        if (c >= 0x20 && c != '"' && c != '\\' && c != 0x7F)
            continue;
        o.put(s[start .. i]);
        start = i + 1;
        switch (c)
        {
        case '"':
            o.put(`\"`);
            break;
        case '\\':
            o.put(`\\`);
            break;
        case '\b':
            o.put(`\b`);
            break;
        case '\t':
            o.put(`\t`);
            break;
        case '\n':
            o.put(`\n`);
            break;
        case '\f':
            o.put(`\f`);
            break;
        case '\r':
            o.put(`\r`);
            break;
        default:
            o.put(`\u00`);
            o.put(hexd[c >> 4]);
            o.put(hexd[c & 15]);
        }
    }
    o.put(s[start .. $]);
    o.put('"');
}
