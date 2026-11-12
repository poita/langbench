/**
 * Canonical TOML serialisation of a document tree.
 *
 * The output is deterministic: keys are sorted by code point, plain
 * key/value pairs come before sub-tables, every table gets an explicit
 * header, and strings are always basic strings. Decoding the output yields
 * the original tree.
 */
module toml.encoder;

import std.array : Appender, appender;
import toml.value;

/// Serialises `root` (which must be a table) to canonical TOML text.
string toToml(Node root) @safe
in (root.kind == Kind.table)
{
    auto app = appender!(char[])();
    writeTable(app, root, "");
    if (app.data.length == 0)
        app ~= '\n';
    return (() @trusted => cast(string) app.data)();
}

private bool isSubTable(Node n) @safe pure nothrow @nogc
{
    return n.kind == Kind.table;
}

private bool isTableArray(Node n) @safe pure nothrow
{
    if (n.kind != Kind.array || n.items.length == 0)
        return false;
    foreach (e; n.items)
        if (e.kind != Kind.table)
            return false;
    return true;
}

private void writeTable(ref Appender!(char[]) app, Node table, string path) @safe
{
    auto keys = table.sortedKeys;
    foreach (k; keys)
    {
        auto v = table.members[k];
        if (isSubTable(v) || isTableArray(v))
            continue;
        writeKey(app, k);
        app ~= " = ";
        writeInline(app, v);
        app ~= '\n';
    }
    foreach (k; keys)
    {
        auto v = table.members[k];
        immutable sub = isSubTable(v);
        if (!sub && !isTableArray(v))
            continue;
        auto childPath = path.length ? path ~ "." ~ renderKey(k) : renderKey(k);
        if (sub)
        {
            header(app, childPath, false);
            writeTable(app, v, childPath);
        }
        else
        {
            foreach (e; v.items)
            {
                header(app, childPath, true);
                writeTable(app, e, childPath);
            }
        }
    }
}

private void header(ref Appender!(char[]) app, string path, bool isArray) @safe
{
    if (app.data.length != 0)
        app ~= '\n';
    app ~= isArray ? "[[" : "[";
    app ~= path;
    app ~= isArray ? "]]\n" : "]\n";
}

private void writeInline(ref Appender!(char[]) app, Node n) @safe
{
    switch (n.kind)
    {
    case Kind.str:
        writeBasicString(app, n.text);
        break;
    case Kind.array:
        app ~= '[';
        foreach (i, e; n.items)
        {
            if (i)
                app ~= ", ";
            writeInline(app, e);
        }
        app ~= ']';
        break;
    case Kind.table:
        app ~= '{';
        bool first = true;
        foreach (k; n.sortedKeys)
        {
            if (!first)
                app ~= ", ";
            first = false;
            writeKey(app, k);
            app ~= " = ";
            writeInline(app, n.members[k]);
        }
        app ~= '}';
        break;
    default:
        app ~= n.text;
    }
}

private bool isBare(const(char)[] k) @safe pure nothrow @nogc
{
    if (k.length == 0)
        return false;
    foreach (c; k)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
              || c == '_' || c == '-'))
            return false;
    return true;
}

private void writeKey(ref Appender!(char[]) app, const(char)[] k) @safe
{
    if (isBare(k))
        app ~= k;
    else
        writeBasicString(app, k);
}

private string renderKey(const(char)[] k) @safe
{
    if (isBare(k))
        return k.idup;
    auto app = appender!(char[])();
    writeBasicString(app, k);
    return (() @trusted => cast(string) app.data)();
}

private void writeBasicString(ref Appender!(char[]) app, const(char)[] s) @safe
{
    static immutable hex = "0123456789abcdef";
    app ~= '"';
    size_t runStart = 0;
    foreach (i, c; s)
    {
        if (c >= 0x20 && c != '"' && c != '\\' && c != 0x7F)
            continue;
        app ~= s[runStart .. i];
        runStart = i + 1;
        switch (c)
        {
        case '"':  app ~= `\"`; break;
        case '\\': app ~= `\\`; break;
        case '\b': app ~= `\b`; break;
        case '\t': app ~= `\t`; break;
        case '\n': app ~= `\n`; break;
        case '\f': app ~= `\f`; break;
        case '\r': app ~= `\r`; break;
        default:
            app ~= `\u00`;
            app ~= hex[c >> 4];
            app ~= hex[c & 15];
        }
    }
    app ~= s[runStart .. $];
    app ~= '"';
}

unittest
{
    import toml.json : fromTaggedJson;

    auto t = fromTaggedJson(`{"db":{"enabled":{"type":"bool","value":"true"},
        "ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]},
        "dob":{"type":"datetime","value":"1979-05-27T07:32:00-08:00"},
        "fruit":[{"name":{"type":"string","value":"apple"}},{"name":{"type":"string","value":"banana"}}],
        "name":{"type":"string","value":"Tom"}}`);
    assert(toToml(t) ==
        "dob = 1979-05-27T07:32:00-08:00\nname = \"Tom\"\n\n[db]\nenabled = true\n"
        ~ "ports = [8001, 8002]\n\n[[fruit]]\nname = \"apple\"\n\n[[fruit]]\nname = \"banana\"\n");
    assert(toToml(Node.newTable()) == "\n");
    auto e = fromTaggedJson(`{"a":{"b":{}},"k y":[{},{"type":"integer","value":"1"}],"e":[]}`);
    assert(toToml(e) == "e = []\n\"k y\" = [{}, 1]\n\n[a]\n\n[a.b]\n");
}
