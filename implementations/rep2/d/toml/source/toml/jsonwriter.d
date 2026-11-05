/// Serialises a `Node` tree as compact, key-sorted tagged JSON (the
/// `toml-test` interchange format).
module toml.jsonwriter;

import std.array : Appender, appender;
import std.algorithm.sorting : sort;
import toml.node;

/**
 * Renders `root` as tagged JSON: no whitespace, object keys sorted by code
 * point, every scalar as `{"type":T,"value":"text"}`.
 */
string toTaggedJson(Node root)
{
    auto app = appender!(char[]);
    app.reserve(4096);
    writeNode(app, root);
    return cast(string) app.data;
}

private:

void writeNode(ref Appender!(char[]) o, Node n)
{
    final switch (n.kind)
    {
    case Kind.table:
        o.put('{');
        auto keys = n.members.keys;
        keys.sort();
        foreach (i, k; keys)
        {
            if (i)
                o.put(',');
            writeJsonString(o, k);
            o.put(':');
            writeNode(o, n.members[k]);
        }
        o.put('}');
        break;
    case Kind.array:
        o.put('[');
        foreach (i, e; n.items)
        {
            if (i)
                o.put(',');
            writeNode(o, e);
        }
        o.put(']');
        break;
    case Kind.string_:
    case Kind.integer:
    case Kind.float_:
    case Kind.boolean:
    case Kind.datetime:
    case Kind.datetimeLocal:
    case Kind.dateLocal:
    case Kind.timeLocal:
        o.put(`{"type":"`);
        o.put(kindNames[n.kind]);
        o.put(`","value":`);
        writeJsonString(o, n.text);
        o.put('}');
        break;
    }
}

/// Writes `s` as a JSON string literal; only `"`, `\` and C0 controls are escaped.
public void writeJsonString(ref Appender!(char[]) o, const(char)[] s)
{
    static immutable hexd = "0123456789abcdef";
    o.put('"');
    size_t start = 0;
    foreach (i, c; s)
    {
        if (c >= 0x20 && c != '"' && c != '\\')
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
        case '\f':
            o.put(`\f`);
            break;
        case '\n':
            o.put(`\n`);
            break;
        case '\r':
            o.put(`\r`);
            break;
        case '\t':
            o.put(`\t`);
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
