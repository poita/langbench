/**
 * The document tree shared by the decoder, the encoder and the JSON layer.
 *
 * A TOML document is represented by a single tree of $(LREF Node)s: tables,
 * arrays and scalars. Scalars keep their canonical text (see `SPEC.md`):
 * integers in decimal, floats as 17 significant digits, date-times
 * normalised, strings after escape processing.
 */
module toml.node;

import core.stdc.stdlib : strtod;
import std.algorithm : sort;
import std.conv : to;
import std.string : toStringz;

/// The type of a $(LREF Node).
enum Kind : ubyte
{
    table,
    array,
    string,
    integer,
    float_,
    boolean,
    datetime,
    datetimeLocal,
    dateLocal,
    timeLocal,
}

/// Thrown for every malformed TOML or JSON document.
class TomlException : Exception
{
    /// 1-based line at which the problem was detected (0 when unknown).
    size_t line;

    this(string msg, size_t line = 0, string file = __FILE__, size_t srcLine = __LINE__) pure nothrow @safe
    {
        super(msg, file, srcLine);
        this.line = line;
    }
}

/// The `"type"` name used for a scalar kind in tagged JSON.
string typeName(Kind k) pure nothrow @safe @nogc
{
    final switch (k)
    {
    case Kind.table:         return "table";
    case Kind.array:         return "array";
    case Kind.string:        return "string";
    case Kind.integer:       return "integer";
    case Kind.float_:        return "float";
    case Kind.boolean:       return "bool";
    case Kind.datetime:      return "datetime";
    case Kind.datetimeLocal: return "datetime-local";
    case Kind.dateLocal:     return "date-local";
    case Kind.timeLocal:     return "time-local";
    }
}

/// Inverse of $(LREF typeName) for scalar kinds. Returns false for anything else.
bool scalarKindFromName(string name, out Kind kind) pure nothrow @safe @nogc
{
    switch (name)
    {
    case "string":         kind = Kind.string; return true;
    case "integer":        kind = Kind.integer; return true;
    case "float":          kind = Kind.float_; return true;
    case "bool":           kind = Kind.boolean; return true;
    case "datetime":       kind = Kind.datetime; return true;
    case "datetime-local": kind = Kind.datetimeLocal; return true;
    case "date-local":     kind = Kind.dateLocal; return true;
    case "time-local":     kind = Kind.timeLocal; return true;
    default:               return false;
    }
}

/// A node of the document tree: a table, an array or a scalar.
final class Node
{
    /// What this node is.
    Kind kind;
    /// Canonical text of a scalar (the string itself for strings).
    string text;
    /// Members of a table.
    Node[string] fields;
    /// Elements of an array.
    Node[] items;

    // Provenance flags used while parsing (see SPEC.md §1.3).
    /// Table opened by a `[header]` or written as an inline table.
    bool explicit;
    /// Table created by an intermediate segment of a dotted key.
    bool dotted;
    /// Closed inline table: nothing may be added to it any more.
    bool sealed;
    /// Array created by `[[header]]` (as opposed to an array literal).
    bool tableArray;

    /// Creates an empty table.
    static Node newTable()
    {
        auto n = new Node;
        n.kind = Kind.table;
        return n;
    }

    /// Creates an empty array.
    static Node newArray()
    {
        auto n = new Node;
        n.kind = Kind.array;
        return n;
    }

    /// Creates a scalar of the given kind with canonical `text`.
    static Node scalar(Kind kind, string text)
    {
        assert(kind != Kind.table && kind != Kind.array);
        auto n = new Node;
        n.kind = kind;
        n.text = text;
        return n;
    }

    /// True for a table.
    bool isTable() const pure nothrow @safe @nogc { return kind == Kind.table; }
    /// True for an array.
    bool isArray() const pure nothrow @safe @nogc { return kind == Kind.array; }
    /// True for any scalar.
    bool isScalar() const pure nothrow @safe @nogc { return kind != Kind.table && kind != Kind.array; }

    /// Number of members (table) or elements (array).
    size_t length() const pure nothrow @safe @nogc
    {
        return kind == Kind.table ? fields.length : items.length;
    }

    /// Table member by key; throws if this is not a table or the key is missing.
    Node opIndex(string key)
    {
        if (kind != Kind.table)
            throw new TomlException("not a table");
        if (auto p = key in fields)
            return *p;
        throw new TomlException("no such key: " ~ key);
    }

    /// Array element by index.
    Node opIndex(size_t i)
    {
        if (kind != Kind.array)
            throw new TomlException("not an array");
        if (i >= items.length)
            throw new TomlException("index out of range");
        return items[i];
    }

    /// Pointer to a table member, or null.
    Node* opBinaryRight(string op : "in")(string key)
    {
        return kind == Kind.table ? key in fields : null;
    }

    /// The member keys of a table in code-point order.
    string[] sortedKeys()
    {
        auto ks = fields.keys;
        ks.sort();
        return ks;
    }

    /// The value of a string node.
    string asString() const
    {
        if (kind != Kind.string)
            throw new TomlException("not a string");
        return text;
    }

    /// The value of an integer node.
    long asInteger() const
    {
        if (kind != Kind.integer)
            throw new TomlException("not an integer");
        return text.to!long;
    }

    /// The value of a float node (NaN loses its sign).
    double asFloat() const
    {
        if (kind != Kind.float_)
            throw new TomlException("not a float");
        return strtod(text.toStringz, null);
    }

    /// The value of a boolean node.
    bool asBool() const
    {
        if (kind != Kind.boolean)
            throw new TomlException("not a boolean");
        return text == "true";
    }
}
