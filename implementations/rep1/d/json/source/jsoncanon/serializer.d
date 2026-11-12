/**
 * Canonical serialization of a $(MREF jsoncanon, value, JsonValue) tree.
 *
 * The canonical form has no whitespace outside strings; object members are
 * sorted by key in UTF-16 code unit order and duplicate keys collapse to the
 * last occurrence; strings escape only what JSON requires. Output is written
 * to a single sink in one pass from the root, so no per-subtree text is
 * built and copied.
 */
module jsoncanon.serializer;

import std.array : appender;
import std.range.primitives : isOutputRange, put;

import jsoncanon.order;
import jsoncanon.value;

/**
 * Writes the canonical serialization of `value` to `sink`, an output range
 * accepting `const(char)[]` (for example `Appender!string` or
 * `Appender!(char[])`).
 */
void writeCanonical(Sink)(ref Sink sink, ref const JsonValue value) @safe
if (isOutputRange!(Sink, const(char)[]))
{
    final switch (value.kind)
    {
    case JsonKind.null_:
        sink.put("null");
        break;
    case JsonKind.false_:
        sink.put("false");
        break;
    case JsonKind.true_:
        sink.put("true");
        break;
    case JsonKind.number:
        sink.put(value.text);
        break;
    case JsonKind.string_:
        writeString(sink, value.text);
        break;
    case JsonKind.array:
        {
            sink.put("[");
            bool first = true;
            foreach (ref item; value.items)
            {
                if (!first)
                    sink.put(",");
                first = false;
                writeCanonical(sink, item);
            }
            sink.put("]");
            break;
        }
    case JsonKind.object:
        writeObject(sink, value.members);
        break;
    }
}

/// Returns the canonical serialization of `value` (no trailing newline).
string toCanonical(ref const JsonValue value) @safe
{
    auto app = appender!string;
    writeCanonical(app, value);
    return app.data;
}

/// ditto
string toCanonical(const JsonValue value) @safe
{
    return toCanonical(value);
}

private void writeObject(Sink)(ref Sink sink, const(JsonMember)[] members) @safe
{
    sink.put("{");
    if (members.length == 1)
    {
        writeMember(sink, members[0]);
    }
    else if (members.length > 1)
    {
        // Sort indices by (key, position); within a run of equal keys the
        // last position is the last occurrence in the input, which wins.
        auto idx = new size_t[members.length];
        foreach (i, ref x; idx)
            x = i;
        sortIndices(idx, members);

        bool first = true;
        foreach (k; 0 .. idx.length)
        {
            if (k + 1 < idx.length && members[idx[k]].key == members[idx[k + 1]].key)
                continue; // a later duplicate follows
            if (!first)
                sink.put(",");
            first = false;
            writeMember(sink, members[idx[k]]);
        }
    }
    sink.put("}");
}

private void sortIndices(size_t[] idx, const(JsonMember)[] members) @trusted
{
    import std.algorithm.sorting : sort;

    idx.sort!((a, b) {
        immutable c = compareUtf16Order(members[a].key, members[b].key);
        return c < 0 || (c == 0 && a < b);
    });
}

private void writeMember(Sink)(ref Sink sink, ref const JsonMember m) @safe
{
    writeString(sink, m.key);
    sink.put(":");
    writeCanonical(sink, m.value);
}

private immutable string hexDigits = "0123456789abcdef";

private void writeString(Sink)(ref Sink sink, const(char)[] s) @safe
{
    sink.put("\"");
    size_t runStart = 0;
    foreach (i; 0 .. s.length)
    {
        immutable char c = s[i];
        if (c >= 0x20 && c != '"' && c != '\\')
            continue;
        if (i > runStart)
            sink.put(s[runStart .. i]);
        runStart = i + 1;
        switch (c)
        {
        case '"':
            sink.put(`\"`);
            break;
        case '\\':
            sink.put(`\\`);
            break;
        case '\b':
            sink.put(`\b`);
            break;
        case '\f':
            sink.put(`\f`);
            break;
        case '\n':
            sink.put(`\n`);
            break;
        case '\r':
            sink.put(`\r`);
            break;
        case '\t':
            sink.put(`\t`);
            break;
        default:
            {
                char[6] esc = ['\\', 'u', '0', '0', hexDigits[c >> 4], hexDigits[c & 15]];
                sink.put(esc[]);
            }
        }
    }
    if (s.length > runStart)
        sink.put(s[runStart .. $]);
    sink.put("\"");
}

version (unittest)
{
    import jsoncanon.parser : parse;

    private string canon(string s) @safe
    {
        return toCanonical(parse(s));
    }
}

@safe unittest
{
    assert(canon("  [ ]  ") == "[]");
    assert(canon("{ }") == "{}");
    assert(canon(`{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }`) == `{"a":"héllo/","b":null}`);
    assert(canon(`["😀", -0, 1e-007, 0.0, 1e-0, "tab\tquote\"nul\u0000 AA"]`)
            == `["😀",-0,1e-7,0.0,1e0,"tab\tquote\"nul\u0000 AA"]`);
    assert(canon(`"\u007f\/\u2028\uD83D\uDE00"`) == "\"\u007f/\u2028\U0001F600\"");
    assert(canon(`{"":1,"😀":2,"￿":3,"Z":4}`)
            == "{\"Z\":4,\"\U0001F600\":2,\"\":1,\"￿\":3}");
}

@safe unittest
{
    // All control characters escape; lowercase hex.
    assert(canon(`"\u001f\u0001\u0000\u000b\u0008\u000c\u000a\u000d\u0009"`)
            == `"\u001f\u0001\u0000\u000b\b\f\n\r\t"`);
    assert(canon(`"\"\\"`) == `"\"\\"`);
}

@safe unittest
{
    // Duplicates: last wins, keys compared decoded; sorted output.
    assert(canon(`{"a":1,"b":2,"a":3}`) == `{"a":3,"b":2}`);
    assert(canon(`{"a":1,"a":2,"a":{"x":1,"x":2}}`) == `{"a":{"x":2}}`);
    assert(canon(`{"b":1,"a":2,"c":3,"a":4,"b":5,"c":6}`) == `{"a":4,"b":5,"c":6}`);
    assert(canon(`{"aa":1,"a":2,"":3}`) == `{"":3,"a":2,"aa":1}`);
    // Nested objects are each sorted.
    assert(canon(`{"z":{"y":1,"x":2},"a":[{"b":1,"a":2}]}`) == `{"a":[{"a":2,"b":1}],"z":{"x":2,"y":1}}`);
}

@safe unittest
{
    import std.array : replicate;

    auto deep = "[".replicate(512) ~ "]".replicate(512);
    assert(canon(deep) == deep);
}
