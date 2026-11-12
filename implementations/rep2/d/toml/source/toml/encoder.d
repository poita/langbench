/**
 * The canonical TOML encoder.
 *
 * Given a `Node` tree it writes a deterministic TOML document: plain
 * key/value pairs first (sorted), then sub-tables and arrays of tables
 * (sorted), each with an explicit header.
 */
module toml.encoder;

import std.array : Appender, appender;

import toml.node;
import toml.utf8 : encodeUtf8;

/// True when `s` can be written as a bare key.
private bool isBareKey(const(char)[] s) @safe pure nothrow @nogc
{
    if (s.length == 0)
        return false;
    foreach (c; s)
    {
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
                || c == '_' || c == '-'))
            return false;
    }
    return true;
}

/// Appends `s` as a TOML basic string (always single-line, always escaped).
void writeBasicString(ref Appender!string sink, const(char)[] s)
{
    static immutable hexDigits = "0123456789abcdef";
    sink.put('"');
    size_t runStart = 0;
    foreach (i, char c; s)
    {
        if (c >= 0x20 && c != 0x7F && c != '"' && c != '\\')
            continue;
        sink.put(s[runStart .. i]);
        runStart = i + 1;
        switch (c)
        {
        case '"': sink.put(`\"`); break;
        case '\\': sink.put(`\\`); break;
        case '\b': sink.put(`\b`); break;
        case '\t': sink.put(`\t`); break;
        case '\n': sink.put(`\n`); break;
        case '\f': sink.put(`\f`); break;
        case '\r': sink.put(`\r`); break;
        default:
            sink.put(`\u00`);
            sink.put(hexDigits[c >> 4]);
            sink.put(hexDigits[c & 15]);
        }
    }
    sink.put(s[runStart .. $]);
    sink.put('"');
}

private void writeKey(ref Appender!string sink, const(char)[] key)
{
    if (isBareKey(key))
        sink.put(key);
    else
        writeBasicString(sink, key);
}

/// A sub-table node, i.e. a table (value nodes are scalars in this model).
private bool isSubTable(Node n) @safe pure nothrow @nogc
{
    return n.isTable;
}

/// A non-empty array whose elements are all tables.
private bool isArrayOfTables(Node n) @safe pure nothrow @nogc
{
    if (!n.isArray || n.items.length == 0)
        return false;
    foreach (e; n.items)
        if (!e.isTable)
            return false;
    return true;
}

private void writeInline(ref Appender!string sink, Node n)
{
    final switch (n.kind)
    {
    case NodeKind.scalar:
        if (n.scalarType == ScalarType.string_)
            writeBasicString(sink, n.text);
        else
            sink.put(n.text);
        break;
    case NodeKind.array:
        sink.put('[');
        foreach (i, e; n.items)
        {
            if (i)
                sink.put(", ");
            writeInline(sink, e);
        }
        sink.put(']');
        break;
    case NodeKind.table:
        sink.put('{');
        bool first = true;
        foreach (k; n.sortedKeys)
        {
            if (!first)
                sink.put(", ");
            first = false;
            writeKey(sink, k);
            sink.put(" = ");
            writeInline(sink, n.entries[k]);
        }
        sink.put('}');
        break;
    }
}

private void writeHeader(ref Appender!string sink, string[] path, bool isArray)
{
    if (sink.data.length != 0)
        sink.put('\n');
    sink.put(isArray ? "[[" : "[");
    foreach (i, k; path)
    {
        if (i)
            sink.put('.');
        writeKey(sink, k);
    }
    sink.put(isArray ? "]]\n" : "]\n");
}

private void writeTable(ref Appender!string sink, Node t, string[] path)
{
    auto keys = t.sortedKeys;
    foreach (k; keys)
    {
        auto v = t.entries[k];
        if (isSubTable(v) || isArrayOfTables(v))
            continue;
        writeKey(sink, k);
        sink.put(" = ");
        writeInline(sink, v);
        sink.put('\n');
    }
    foreach (k; keys)
    {
        auto v = t.entries[k];
        if (isSubTable(v))
        {
            auto sub = path ~ k;
            writeHeader(sink, sub, false);
            writeTable(sink, v, sub);
        }
        else if (isArrayOfTables(v))
        {
            auto sub = path ~ k;
            foreach (e; v.items)
            {
                writeHeader(sink, sub, true);
                writeTable(sink, e, sub);
            }
        }
    }
}

/**
 * Renders a root table as canonical TOML.
 *
 * Params:
 *     root = the root table
 * Returns: the document, ending in a single newline
 */
string toToml(Node root)
{
    assert(root.isTable, "the root of a document must be a table");
    auto sink = appender!string();
    writeTable(sink, root, null);
    if (sink.data.length == 0)
        sink.put('\n');
    return sink.data;
}

unittest
{
    import toml.json : fromTaggedJson;

    assert(toToml(table()) == "\n");

    auto doc = fromTaggedJson(`{"db":{"enabled":{"type":"bool","value":"true"},
        "ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]},
        "dob":{"type":"datetime","value":"1979-05-27T07:32:00-08:00"},
        "fruit":[{"name":{"type":"string","value":"apple"}},{"name":{"type":"string","value":"banana"}}],
        "name":{"type":"string","value":"Tom"}}`);
    assert(toToml(doc) ==
        "dob = 1979-05-27T07:32:00-08:00\nname = \"Tom\"\n\n[db]\nenabled = true\n"
        ~ "ports = [8001, 8002]\n\n[[fruit]]\nname = \"apple\"\n\n[[fruit]]\nname = \"banana\"\n");
}

unittest
{
    import toml.json : fromTaggedJson;

    // Header first on the very first line has no blank line; nested empty
    // tables get headers; mixed arrays and key quoting.
    auto doc = fromTaggedJson(`{"a":{"b":{}},"x y":[{"k":{"type":"integer","value":"1"}}, {"type":"integer","value":"2"}],
        "":{"type":"string","value":"q\"\u0001\u007f"}, "e":[], "t":[[{}],[]]}`);
    assert(toToml(doc) ==
        "\"\" = \"q\\\"\\u0001\\u007f\"\ne = []\nt = [[{}], []]\n\"x y\" = [{k = 1}, 2]\n\n[a]\n\n[a.b]\n");
    auto d2 = fromTaggedJson(`{"a":{"b":{}}}`);
    assert(toToml(d2) == "[a]\n\n[a.b]\n");
}
