/**
 * The in-memory document model shared by the decoder, the encoder and the
 * tagged-JSON reader/writer.
 *
 * A document is a tree of `Node`s. Scalars keep their *canonical text* (see
 * the `text` field) rather than a native number or date, so that nothing is
 * lost or altered when a document is converted from one form to another.
 */
module toml.node;

import std.algorithm.sorting : sort;
import std.array : array;

/// Thrown when a document is not valid TOML (or not valid tagged JSON).
class TomlException : Exception
{
    /// Byte offset in the input at which the problem was detected, or
    /// `size_t.max` when unknown.
    size_t offset;

    this(string msg, size_t offset = size_t.max,
         string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
        this.offset = offset;
    }
}

/// The three structural kinds of node.
enum NodeKind
{
    table,  /// a mapping from keys to nodes
    array,  /// an ordered list of nodes
    scalar, /// a string, number, boolean or date/time
}

/// The type of a scalar node. Names match the `toml-test` tagged-JSON tags.
enum ScalarType
{
    string_,       /// `string`
    integer,       /// `integer`
    float_,        /// `float`
    boolean,       /// `bool`
    datetime,      /// `datetime` (offset date-time)
    datetimeLocal, /// `datetime-local`
    dateLocal,     /// `date-local`
    timeLocal,     /// `time-local`
}

private immutable string[8] typeNames = [
    "string", "integer", "float", "bool",
    "datetime", "datetime-local", "date-local", "time-local",
];

/// The tagged-JSON name of a scalar type, e.g. `"datetime-local"`.
string typeName(ScalarType t) @safe pure nothrow @nogc
{
    return typeNames[t];
}

/// Looks up a scalar type by its tagged-JSON name. Returns false if unknown.
bool typeFromName(const(char)[] name, out ScalarType t) @safe pure nothrow @nogc
{
    foreach (i, n; typeNames)
    {
        if (n == name)
        {
            t = cast(ScalarType) i;
            return true;
        }
    }
    return false;
}

/**
 * A node of a TOML document tree.
 *
 * Use the `table`, `array` and `scalar` factory functions to create nodes.
 */
final class Node
{
    /// Which kind of node this is.
    NodeKind kind;

    // ---- scalar ----------------------------------------------------------
    /// For scalars: the type.
    ScalarType scalarType;
    /// For scalars: the canonical text (the string itself for strings; the
    /// decimal form for integers; the 17-digit form for floats; ...).
    string text;

    // ---- array -----------------------------------------------------------
    /// For arrays: the elements, in document order.
    Node[] items;
    /// For arrays: true when created by `[[header]]` syntax.
    bool arrayOfTables;

    // ---- table -----------------------------------------------------------
    /// For tables: the members.
    Node[string] entries;
    /// For tables: opened by a `[header]` or written as an inline table.
    bool explicit;
    /// For tables: created by an intermediate segment of a dotted key.
    bool dotted;
    /// For tables: written as an inline table (closed to later additions).
    bool inline;

    private this(NodeKind k) @safe pure nothrow
    {
        kind = k;
    }

    /// The keys of a table in ascending code point order.
    string[] sortedKeys() pure
    {
        auto ks = entries.keys;
        ks.sort();
        return ks;
    }

    /// True when this is a table.
    bool isTable() const @safe pure nothrow @nogc { return kind == NodeKind.table; }
    /// True when this is an array.
    bool isArray() const @safe pure nothrow @nogc { return kind == NodeKind.array; }
    /// True when this is a scalar.
    bool isScalar() const @safe pure nothrow @nogc { return kind == NodeKind.scalar; }

    /// Member lookup on a table; returns null when absent.
    Node opIndex(string key) pure
    {
        assert(kind == NodeKind.table);
        auto p = key in entries;
        return p ? *p : null;
    }
}

/// Creates an empty table node.
Node table() @safe pure nothrow
{
    return new Node(NodeKind.table);
}

/// Creates an array node holding `items`.
Node array(Node[] items = null) @safe pure nothrow
{
    auto n = new Node(NodeKind.array);
    n.items = items;
    return n;
}

/// Creates a scalar node of type `t` with canonical text `text`.
Node scalar(ScalarType t, string text) @safe pure nothrow
{
    auto n = new Node(NodeKind.scalar);
    n.scalarType = t;
    n.text = text;
    return n;
}

unittest
{
    auto t = table();
    t.entries["b"] = scalar(ScalarType.integer, "1");
    t.entries["a"] = scalar(ScalarType.string_, "x");
    t.entries["é"] = array();
    assert(t.sortedKeys == ["a", "b", "é"]);
    assert(t["a"].text == "x");
    assert(t["zzz"] is null);
    ScalarType ty;
    assert(typeFromName("datetime-local", ty) && ty == ScalarType.datetimeLocal);
    assert(!typeFromName("nope", ty));
    assert(typeName(ScalarType.boolean) == "bool");
}
