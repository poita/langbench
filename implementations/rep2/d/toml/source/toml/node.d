/// The in-memory document tree shared by the decoder and the encoder.
module toml.node;

import toml.errors : TomlException;

/// What a `Node` holds.
enum Kind : ubyte
{
    table,         /// a table: string keys mapping to nodes
    array,         /// an array of nodes
    string_,       /// a string
    integer,       /// a 64-bit signed integer
    float_,        /// a binary64 float
    boolean,       /// `true` or `false`
    datetime,      /// offset date-time
    datetimeLocal, /// local date-time
    dateLocal,     /// local date
    timeLocal,     /// local time
}

/// How a table came into existence. Drives the redefinition rules of TOML.
enum Origin : ubyte
{
    implicit, /// created as an intermediate segment of a `[header]`
    explicit, /// created by a `[header]` line (or is the root)
    dotted,   /// created as an intermediate segment of a dotted key
    inline,   /// an inline table literal, or something inside one (closed)
}

/// The tagged-JSON `"type"` name for each scalar kind.
immutable string[10] kindNames = [
    "table", "array", "string", "integer", "float", "bool",
    "datetime", "datetime-local", "date-local", "time-local",
];

/// Returns the kind named by a tagged-JSON type string, or `false`.
bool kindFromName(const(char)[] name, out Kind kind) @safe pure nothrow @nogc
{
    foreach (i; Kind.string_ .. Kind.max + 1)
    {
        if (kindNames[i] == name)
        {
            kind = cast(Kind) i;
            return true;
        }
    }
    return false;
}

/**
 * A node of a TOML document.
 *
 * Scalars keep their canonical text (see the README): the decoded string
 * itself, a decimal integer, a 17-significant-digit float, and so on. Typed
 * accessors (`integer`, `floating`, ...) convert on demand.
 */
final class Node
{
    /// What this node holds.
    Kind kind;
    /// For tables: how the table was created.
    Origin origin;
    /// For arrays: `true` when created by `[[header]]` lines.
    bool isTableArray;
    /// Scalars: the canonical text.
    string text;
    /// Tables: the members.
    Node[string] members;
    /// Arrays: the elements.
    Node[] items;

    /// Creates an empty table.
    static Node newTable(Origin origin = Origin.explicit) pure nothrow
    {
        auto n = new Node;
        n.kind = Kind.table;
        n.origin = origin;
        return n;
    }

    /// Creates an empty array.
    static Node newArray(bool isTableArray = false) pure nothrow
    {
        auto n = new Node;
        n.kind = Kind.array;
        n.isTableArray = isTableArray;
        return n;
    }

    /// Creates a scalar node of the given kind with canonical `text`.
    static Node newScalar(Kind kind, string text) pure nothrow
    in (kind != Kind.table && kind != Kind.array)
    {
        auto n = new Node;
        n.kind = kind;
        n.text = text;
        return n;
    }

    /// Creates a string node.
    static Node fromString(string s) pure nothrow
    {
        return newScalar(Kind.string_, s);
    }

    /// Creates an integer node.
    static Node fromInteger(long v) pure
    {
        import std.conv : to;

        return newScalar(Kind.integer, v.to!string);
    }

    /// Creates a float node (canonical 17-digit text).
    static Node fromFloat(double v)
    {
        import toml.floatfmt : formatFloat;

        return newScalar(Kind.float_, formatFloat(v));
    }

    /// Creates a boolean node.
    static Node fromBool(bool v) pure nothrow
    {
        return newScalar(Kind.boolean, v ? "true" : "false");
    }

    /// True for tables.
    bool isTable() const pure nothrow @nogc => kind == Kind.table;
    /// True for arrays.
    bool isArray() const pure nothrow @nogc => kind == Kind.array;
    /// True for everything that is neither a table nor an array.
    bool isScalar() const pure nothrow @nogc => kind != Kind.table && kind != Kind.array;

    /// Number of members (tables) or elements (arrays); 0 for scalars.
    size_t length() const pure nothrow @nogc
    {
        if (kind == Kind.table)
            return members.length;
        if (kind == Kind.array)
            return items.length;
        return 0;
    }

    /// Looks up a member of a table. Throws if this is not a table or the key is missing.
    Node opIndex(string key)
    {
        enforceKind(Kind.table);
        if (auto p = key in members)
            return *p;
        throw new TomlException("no such key: " ~ key);
    }

    /// Returns a pointer to a member of a table, or `null`.
    Node* opBinaryRight(string op : "in")(string key)
    {
        return kind == Kind.table ? key in members : null;
    }

    /// Element `i` of an array.
    Node opIndex(size_t i)
    {
        enforceKind(Kind.array);
        if (i >= items.length)
            throw new TomlException("array index out of range");
        return items[i];
    }

    /// The text of a string node.
    string str() const
    {
        enforceKind(Kind.string_);
        return text;
    }

    /// The value of an integer node.
    long integer() const
    {
        import std.conv : to;

        enforceKind(Kind.integer);
        return text.to!long;
    }

    /// The value of a float node.
    double floating() const
    {
        import toml.floatfmt : parseFloatText;

        enforceKind(Kind.float_);
        return parseFloatText(text);
    }

    /// The value of a boolean node.
    bool boolean() const
    {
        enforceKind(Kind.boolean);
        return text == "true";
    }

    /// Table keys in ascending (code point) order.
    string[] sortedKeys() const
    {
        import std.algorithm.sorting : sort;

        enforceKind(Kind.table);
        auto ks = members.keys;
        ks.sort();
        return ks;
    }

    private void enforceKind(Kind k) const
    {
        if (kind != k)
            throw new TomlException("node is a " ~ kindNames[kind] ~ ", expected " ~ kindNames[k]);
    }
}
