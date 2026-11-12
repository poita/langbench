/**
 * The document tree shared by the parser and the serializers.
 *
 * A TOML document is a tree of `Node`s.  Scalars keep their canonical *text*
 * (see the `toml.number` and `toml.datetime` modules); they are converted to
 * D numbers only on request, through `asLong`, `asDouble` and friends.
 */
module toml.value;

import toml.exception : TomlException;

/// What a `Node` holds.
enum Kind : ubyte
{
    /// A string; `text` is the decoded content.
    str,
    /// A 64-bit signed integer; `text` is its decimal form.
    integer,
    /// A float; `text` is `nan`, `inf`, `-inf` or 17-digit scientific notation.
    floating,
    /// `true` or `false`.
    boolean,
    /// A date-time with an offset: `1979-05-27T07:32:00Z`.
    offsetDateTime,
    /// A date-time without an offset: `1979-05-27T07:32:00`.
    localDateTime,
    /// A date: `1979-05-27`.
    localDate,
    /// A time: `07:32:00`.
    localTime,
    /// An array; the elements are in `items`.
    array,
    /// A table; the entries are in `members`.
    table,
}

/// The type name used for a scalar `Kind` in the toml-test tagged JSON format.
string typeName(Kind k) @safe pure nothrow @nogc
{
    final switch (k)
    {
    case Kind.str:            return "string";
    case Kind.integer:        return "integer";
    case Kind.floating:       return "float";
    case Kind.boolean:        return "bool";
    case Kind.offsetDateTime: return "datetime";
    case Kind.localDateTime:  return "datetime-local";
    case Kind.localDate:      return "date-local";
    case Kind.localTime:      return "time-local";
    case Kind.array:          return "array";
    case Kind.table:          return "table";
    }
}

/// The inverse of `typeName` for the eight scalar types. Returns false for other names.
bool kindFromTypeName(const(char)[] name, out Kind kind) @safe pure nothrow @nogc
{
    switch (name)
    {
    case "string":         kind = Kind.str;            return true;
    case "integer":        kind = Kind.integer;        return true;
    case "float":          kind = Kind.floating;       return true;
    case "bool":           kind = Kind.boolean;        return true;
    case "datetime":       kind = Kind.offsetDateTime; return true;
    case "datetime-local": kind = Kind.localDateTime;  return true;
    case "date-local":     kind = Kind.localDate;      return true;
    case "time-local":     kind = Kind.localTime;      return true;
    default:               return false;
    }
}

/// How a table came into existence. Used by the parser to enforce TOML's redefinition rules.
package(toml) enum TableState : ubyte
{
    /// Created only as an intermediate segment of a `[header]`.
    implicit,
    /// Opened by a `[header]` or `[[header]]` line.
    explicit,
    /// Created as an intermediate segment of a dotted key.
    dotted,
    /// An inline table literal (closed: it can no longer be extended).
    inlineTable,
}

/// One node of a document tree: a table, an array or a scalar.
final class Node
{
    /// What this node holds.
    Kind kind;
    /// The canonical text of a scalar (the decoded content for strings).
    string text;
    /// The elements of an array.
    Node[] items;
    /// The entries of a table, by key.
    Node[string] members;

    package(toml) TableState state;
    /// True for arrays that were created by `[[header]]` lines.
    package(toml) bool fromHeader;

    /// Creates an empty table.
    static Node newTable() @safe pure nothrow
    {
        auto n = new Node;
        n.kind = Kind.table;
        return n;
    }

    /// Creates an empty array.
    static Node newArray() @safe pure nothrow
    {
        auto n = new Node;
        n.kind = Kind.array;
        return n;
    }

    /// Creates a scalar of the given kind whose canonical text is `text`.
    static Node scalar(Kind kind, string text) @safe pure nothrow
    in (kind != Kind.array && kind != Kind.table)
    {
        auto n = new Node;
        n.kind = kind;
        n.text = text;
        return n;
    }

    /// Creates a string node.
    static Node fromString(string s) @safe pure nothrow
    {
        return scalar(Kind.str, s);
    }

    /// Creates an integer node.
    static Node fromLong(long v) @safe pure
    {
        import toml.number : formatInteger;

        return scalar(Kind.integer, formatInteger(v < 0, v < 0 ? -cast(ulong) v : cast(ulong) v));
    }

    /// Creates a float node.
    static Node fromDouble(double v) @trusted
    {
        import toml.number : formatFloat;

        return scalar(Kind.floating, formatFloat(v));
    }

    /// Creates a boolean node.
    static Node fromBool(bool v) @safe pure nothrow
    {
        return scalar(Kind.boolean, v ? "true" : "false");
    }

    /// True if this node is a table.
    bool isTable() const @safe pure nothrow @nogc { return kind == Kind.table; }
    /// True if this node is an array.
    bool isArray() const @safe pure nothrow @nogc { return kind == Kind.array; }
    /// True if this node is a scalar.
    bool isScalar() const @safe pure nothrow @nogc { return kind < Kind.array; }

    /// Number of elements (array) or entries (table); 0 for scalars.
    size_t length() const @safe pure nothrow @nogc
    {
        return kind == Kind.array ? items.length : kind == Kind.table ? members.length : 0;
    }

    /// Looks up a table entry. Throws `TomlException` when this is not a table or the key is absent.
    Node opIndex(string key)
    {
        if (kind != Kind.table)
            throw new TomlException("not a table");
        if (auto p = key in members)
            return *p;
        throw new TomlException("no such key: " ~ key);
    }

    /// Returns the `i`th element of an array. Throws `TomlException` when out of range.
    Node opIndex(size_t i)
    {
        if (kind != Kind.array)
            throw new TomlException("not an array");
        if (i >= items.length)
            throw new TomlException("array index out of range");
        return items[i];
    }

    /// Pointer to the entry for `key`, or null (also null when this is not a table).
    inout(Node)* opBinaryRight(string op : "in")(string key) inout @safe pure nothrow
    {
        if (kind != Kind.table)
            return null;
        return key in members;
    }

    /// The keys of a table in ascending (code point) order.
    string[] sortedKeys() const @safe pure
    {
        import std.algorithm.sorting : sort;

        string[] ks;
        ks.reserve(members.length);
        foreach (k; members.byKey)
            ks ~= k;
        sort(ks);
        return ks;
    }

    /// The string content. Throws unless this is a string.
    string asString() const { expect(Kind.str); return text; }

    /// The integer value. Throws unless this is an integer.
    long asLong() const
    {
        import std.conv : to;

        expect(Kind.integer);
        return to!long(text);
    }

    /// The float value. Throws unless this is a float.
    double asDouble() const @trusted
    {
        import std.string : toStringz;
        import core.stdc.stdlib : strtod;

        expect(Kind.floating);
        return strtod(toStringz(text), null);
    }

    /// The boolean value. Throws unless this is a boolean.
    bool asBool() const { expect(Kind.boolean); return text == "true"; }

    private void expect(Kind k) const
    {
        if (kind != k)
            throw new TomlException("expected " ~ typeName(k) ~ " but found " ~ typeName(kind));
    }
}

unittest
{
    auto t = Node.newTable();
    t.members["a"] = Node.fromLong(-5);
    t.members["b"] = Node.fromDouble(1.0);
    t.members["c"] = Node.fromBool(true);
    t.members["d"] = Node.fromString("hi");
    assert(t["a"].asLong == -5);
    assert(t["b"].text == "1.0000000000000000e+00");
    assert(t["b"].asDouble == 1.0);
    assert(t["c"].asBool);
    assert(t["d"].asString == "hi");
    assert(t.sortedKeys == ["a", "b", "c", "d"]);
    assert(("zz" in t) is null);
    assert(("a" in t) !is null);
    assert(Node.fromLong(long.min).text == "-9223372036854775808");
}
