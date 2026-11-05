/// The document tree produced by the parser and consumed by the writers.
module toml.node;

import toml.exception;

/// What a `Node` holds.
enum Kind : ubyte
{
    table,          /// key/value table (`members`)
    array,          /// array (`elements`)
    string_,        /// string; `text` is the decoded value
    integer,        /// integer; `text` is the canonical decimal form
    float_,         /// float; `text` is the canonical 17-digit form, `inf`, `-inf` or `nan`
    boolean,        /// `text` is `true` or `false`
    offsetDateTime, /// RFC 3339 date-time with offset
    localDateTime,  /// date-time without offset
    localDate,      /// date only
    localTime,      /// time only
}

/// Names of the scalar kinds in the tagged-JSON format.
string typeName(Kind k) pure nothrow @safe @nogc
{
    final switch (k)
    {
    case Kind.table:          return "table";
    case Kind.array:          return "array";
    case Kind.string_:        return "string";
    case Kind.integer:        return "integer";
    case Kind.float_:         return "float";
    case Kind.boolean:        return "bool";
    case Kind.offsetDateTime: return "datetime";
    case Kind.localDateTime:  return "datetime-local";
    case Kind.localDate:      return "date-local";
    case Kind.localTime:      return "time-local";
    }
}

/// Inverse of `typeName` for scalar kinds. Returns false when `name` is unknown.
bool kindFromTypeName(const(char)[] name, out Kind k) pure nothrow @safe @nogc
{
    switch (name)
    {
    case "string":         k = Kind.string_;        return true;
    case "integer":        k = Kind.integer;        return true;
    case "float":          k = Kind.float_;         return true;
    case "bool":           k = Kind.boolean;        return true;
    case "datetime":       k = Kind.offsetDateTime; return true;
    case "datetime-local": k = Kind.localDateTime;  return true;
    case "date-local":     k = Kind.localDate;      return true;
    case "time-local":     k = Kind.localTime;      return true;
    default:               return false;
    }
}

/**
 * A node of a TOML document: a table, an array or a scalar.
 *
 * Scalars keep their canonical text form (see the tagged-JSON format), and
 * typed accessors convert on demand. Tables keep the provenance flags needed
 * by the parser to enforce TOML's table-definition rules.
 */
final class Node
{
    /// The node's kind.
    Kind kind;
    /// Scalar value in canonical text form (unused for tables and arrays).
    string text;
    /// Table members, keyed by decoded key.
    Node[string] members;
    /// Array elements in document order.
    Node[] elements;

    // Provenance flags used while parsing.
    package bool explicit_; // opened by [header] or written as an inline table
    package bool dotted;    // created as an intermediate segment of a dotted key
    package bool sealed;    // part of a closed inline table
    package bool aot;       // array created by [[header]]

    /// Creates an empty table.
    static Node newTable() pure nothrow @safe
    {
        auto n = new Node;
        n.kind = Kind.table;
        return n;
    }

    /// Creates an empty array.
    static Node newArray() pure nothrow @safe
    {
        auto n = new Node;
        n.kind = Kind.array;
        return n;
    }

    /// Creates a scalar of the given kind from its canonical text.
    static Node newScalar(Kind kind, string text) pure nothrow @safe
    {
        auto n = new Node;
        n.kind = kind;
        n.text = text;
        return n;
    }

    /// Creates a string scalar.
    static Node fromString(string s) pure nothrow @safe { return newScalar(Kind.string_, s); }

    /// Creates an integer scalar.
    static Node fromLong(long v) pure @safe
    {
        import std.conv : to;
        return newScalar(Kind.integer, v.to!string);
    }

    /// Creates a boolean scalar.
    static Node fromBool(bool b) pure nothrow @safe { return newScalar(Kind.boolean, b ? "true" : "false"); }

    /// True for tables.
    bool isTable() const pure nothrow @safe @nogc { return kind == Kind.table; }
    /// True for arrays.
    bool isArray() const pure nothrow @safe @nogc { return kind == Kind.array; }
    /// True for everything that is neither a table nor an array.
    bool isScalar() const pure nothrow @safe @nogc { return kind != Kind.table && kind != Kind.array; }

    /// Table lookup; throws `TomlException` if this is not a table or the key is missing.
    Node opIndex(string key)
    {
        if (!isTable) throw new TomlException("not a table");
        if (auto p = key in members) return *p;
        throw new TomlException("missing key: " ~ key);
    }

    /// Array indexing; throws `TomlException` if this is not an array or the index is out of range.
    Node opIndex(size_t i)
    {
        if (!isArray) throw new TomlException("not an array");
        if (i >= elements.length) throw new TomlException("index out of range");
        return elements[i];
    }

    /// Table membership test: returns a pointer to the member or null.
    Node* opBinaryRight(string op : "in")(string key) pure nothrow @safe
    {
        return isTable ? key in members : null;
    }

    /// Number of members (tables) or elements (arrays); 0 for scalars.
    size_t length() const pure nothrow @safe @nogc
    {
        return isTable ? members.length : isArray ? elements.length : 0;
    }

    /// The decoded value of a string scalar.
    string asString() const
    {
        if (kind != Kind.string_) throw new TomlException("not a string");
        return text;
    }

    /// The value of an integer scalar.
    long asLong() const
    {
        import std.conv : to;
        if (kind != Kind.integer) throw new TomlException("not an integer");
        return text.to!long;
    }

    /// The value of a float scalar (integers are not converted).
    double asDouble() const
    {
        import toml.number : textToDouble;
        if (kind != Kind.float_) throw new TomlException("not a float");
        return textToDouble(text);
    }

    /// The value of a boolean scalar.
    bool asBool() const
    {
        if (kind != Kind.boolean) throw new TomlException("not a boolean");
        return text == "true";
    }
}
