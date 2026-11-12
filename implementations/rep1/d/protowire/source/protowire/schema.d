/// Message schema: descriptors and the schema text parser.
///
/// The schema language is a tiny subset of protobuf:
/// ---
/// message Inner { sint32 v = 1; }
/// message Outer { int32 a = 1; repeated int32 c = 3; Inner d = 4; }
/// ---
module protowire.schema;

import protowire.errors : SchemaException;
import protowire.wire : WireType;

/// The type of a field. `message` fields refer to another `MessageDescriptor`.
enum FieldKind : ubyte
{
    int32, int64, uint32, uint64, sint32, sint64, bool_,
    fixed32, fixed64, sfixed32, sfixed64,
    string_, bytes_,
    message,
}

/// True for the kinds that are numbers or booleans (and so may be packed).
bool isNumeric(FieldKind k) @safe pure nothrow @nogc
{
    return k < FieldKind.string_;
}

/// True for kinds printed and range-checked as signed integers.
bool isSigned(FieldKind k) @safe pure nothrow @nogc
{
    with (FieldKind)
        return k == int32 || k == int64 || k == sint32 || k == sint64
            || k == sfixed32 || k == sfixed64;
}

/// Width in bits of an integer kind (32 or 64); 0 for non-integers and bool.
uint bitWidth(FieldKind k) @safe pure nothrow @nogc
{
    with (FieldKind)
        switch (k)
        {
        case int32, uint32, sint32, fixed32, sfixed32:
            return 32;
        case int64, uint64, sint64, fixed64, sfixed64:
            return 64;
        default:
            return 0;
        }
}

/// The wire type used for one value (or one unpacked element) of kind `k`.
WireType wireTypeOf(FieldKind k) @safe pure nothrow @nogc
{
    with (FieldKind)
        switch (k)
        {
        case fixed32, sfixed32:
            return WireType.fixed32;
        case fixed64, sfixed64:
            return WireType.fixed64;
        case string_, bytes_, message:
            return WireType.lengthDelimited;
        default:
            return WireType.varint;
        }
}

/// One field of a message.
struct FieldDescriptor
{
    string name;
    uint number;
    FieldKind kind;
    bool repeated;
    /// For `FieldKind.message` fields, the message type; otherwise null.
    MessageDescriptor message;
}

/// A message type: its fields, ordered by field number, with O(1) lookup.
final class MessageDescriptor
{
    /// Name of the message.
    string name;
    /// Fields sorted by increasing field number.
    FieldDescriptor[] fields;

    private size_t[uint] byNumber;
    private size_t[string] byName;

    this(string name) @safe pure nothrow
    {
        this.name = name;
    }

    /// Index into `fields` of the field with this number, or -1.
    ptrdiff_t indexOfNumber(uint number) const @safe pure nothrow
    {
        if (auto p = number in byNumber)
            return cast(ptrdiff_t)*p;
        return -1;
    }

    /// Index into `fields` of the field with this name, or -1.
    ptrdiff_t indexOfName(scope const(char)[] fieldName) const @trusted pure nothrow
    {
        // The cast only widens the key for a read-only lookup.
        if (auto p = (cast(string) fieldName) in byName)
            return cast(ptrdiff_t)*p;
        return -1;
    }

    // Sorts the fields and builds the lookup tables. Called by the schema parser.
    private void finish() @safe pure
    {
        import std.algorithm.sorting : sort;

        fields.sort!((a, b) => a.number < b.number);
        foreach (i, ref f; fields)
        {
            byNumber[f.number] = i;
            byName[f.name] = i;
        }
    }
}

/// A set of message types parsed from schema text.
final class Schema
{
    /// All messages in definition order.
    MessageDescriptor[] messages;
    private MessageDescriptor[string] byName;

    /// Parses schema text. Throws `SchemaException` on malformed input.
    static Schema parse(scope const(char)[] text) @safe
    {
        return parseSchema(text);
    }

    /// The message called `name`, or null if there is none.
    MessageDescriptor find(scope const(char)[] name) @trusted pure nothrow
    {
        if (auto p = (cast(string) name) in byName)
            return *p;
        return null;
    }

    /// The message called `name`; throws `SchemaException` if there is none.
    MessageDescriptor opIndex(scope const(char)[] name) @safe pure
    {
        if (auto m = find(name))
            return m;
        throw new SchemaException("unknown message: " ~ name.idup);
    }
}

private bool isNameChar(char c) @safe pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

/// Splits schema text into tokens: `{ } ; =` or maximal runs of `[A-Za-z0-9_]`.
/// Whitespace (space, tab, CR, LF) separates tokens; any other character is an error.
private const(char)[][] tokenize(const(char)[] text) @safe pure
{
    const(char)[][] tokens;
    size_t i = 0;
    while (i < text.length)
    {
        immutable c = text[i];
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
        {
            ++i;
        }
        else if (c == '{' || c == '}' || c == ';' || c == '=')
        {
            tokens ~= text[i .. i + 1];
            ++i;
        }
        else if (isNameChar(c))
        {
            immutable start = i;
            while (i < text.length && isNameChar(text[i]))
                ++i;
            tokens ~= text[start .. i];
        }
        else
        {
            throw new SchemaException("unexpected character in schema");
        }
    }
    return tokens;
}

private immutable FieldKind[string] scalarKinds;

shared static this()
{
    scalarKinds = [
        "int32": FieldKind.int32, "int64": FieldKind.int64,
        "uint32": FieldKind.uint32, "uint64": FieldKind.uint64,
        "sint32": FieldKind.sint32, "sint64": FieldKind.sint64,
        "bool": FieldKind.bool_,
        "fixed32": FieldKind.fixed32, "fixed64": FieldKind.fixed64,
        "sfixed32": FieldKind.sfixed32, "sfixed64": FieldKind.sfixed64,
        "string": FieldKind.string_, "bytes": FieldKind.bytes_,
    ];
}

private uint parseFieldNumber(const(char)[] tok) @safe pure
{
    if (tok.length == 0 || tok.length > 9)
        throw new SchemaException("bad field number");
    uint n = 0;
    foreach (c; tok)
    {
        if (c < '0' || c > '9')
            throw new SchemaException("bad field number");
        n = n * 10 + (c - '0');
    }
    if (n < 1 || n > 536_870_911)
        throw new SchemaException("field number out of range");
    return n;
}

private Schema parseSchema(const(char)[] text) @safe
{
    auto tokens = tokenize(text);
    auto schema = new Schema;

    struct Body
    {
        MessageDescriptor desc;
        size_t begin, end; // token range of the fields
    }

    Body[] bodies;

    // Pass 1: find every message so that field types may refer forward.
    size_t i = 0;
    while (i < tokens.length)
    {
        if (tokens[i] != "message" || i + 2 >= tokens.length || tokens[i + 2] != "{")
            throw new SchemaException("expected 'message <Name> {'");
        immutable name = tokens[i + 1].idup;
        if (name in schema.byName)
            throw new SchemaException("duplicate message: " ~ name);
        auto desc = new MessageDescriptor(name);
        schema.messages ~= desc;
        schema.byName[name] = desc;
        immutable begin = i + 3;
        i = begin;
        while (i < tokens.length && tokens[i] != "}")
            ++i;
        if (i >= tokens.length)
            throw new SchemaException("missing '}'");
        bodies ~= Body(desc, begin, i);
        ++i;
    }

    // Pass 2: fields.
    foreach (b; bodies)
    {
        auto toks = tokens[b.begin .. b.end];
        size_t j = 0;
        while (j < toks.length)
        {
            bool repeated = false;
            if (toks[j] == "repeated")
            {
                repeated = true;
                ++j;
            }
            if (j + 5 > toks.length)
                throw new SchemaException("incomplete field");
            const typeName = toks[j];
            immutable fieldName = toks[j + 1].idup;
            if (toks[j + 2] != "=" || toks[j + 4] != ";")
                throw new SchemaException("malformed field");
            FieldDescriptor f;
            f.name = fieldName;
            f.number = parseFieldNumber(toks[j + 3]);
            f.repeated = repeated;
            if (auto k = typeName in scalarKinds)
            {
                f.kind = *k;
            }
            else if (auto m = typeName in schema.byName)
            {
                f.kind = FieldKind.message;
                f.message = *m;
            }
            else
            {
                throw new SchemaException("unknown type: " ~ typeName.idup);
            }
            b.desc.fields ~= f;
            j += 5;
        }
        b.desc.finish();
    }
    return schema;
}

@safe unittest
{
    auto s = Schema.parse("message Inner { sint32 v = 1; }\n"
            ~ "message Outer {\n int32 a = 1;\n repeated int32 c = 3;\n Inner d = 4; string b = 2; }");
    assert(s.messages.length == 2);
    auto o = s["Outer"];
    assert(o.fields.length == 4);
    assert(o.fields[1].name == "b" && o.fields[1].number == 2); // sorted by number
    assert(o.fields[2].repeated && o.fields[2].kind == FieldKind.int32);
    assert(o.fields[3].kind == FieldKind.message && o.fields[3].message is s["Inner"]);
    assert(o.indexOfNumber(4) == 3 && o.indexOfNumber(5) == -1);
    assert(o.indexOfName("c") == 2 && o.indexOfName("zz") == -1);
    assert(s.find("Nope") is null);
}

@safe unittest
{
    // compact punctuation, forward and recursive references
    auto s = Schema.parse("message A{B b=1;repeated A kids=2;}message B{bool x=3;}");
    assert(s["A"].fields[0].message is s["B"]);
    assert(s["A"].fields[1].message is s["A"] && s["A"].fields[1].repeated);
}

@safe unittest
{
    import std.exception : assertThrown;

    assertThrown!SchemaException(Schema.parse("message A { int32 x = 1 }"));
    assertThrown!SchemaException(Schema.parse("message A { Foo x = 1; }"));
    assertThrown!SchemaException(Schema.parse("message A { int32 x = 1;"));
    assertThrown!SchemaException(Schema.parse("message A { int32 x = 0; }"));
    assertThrown!SchemaException(Schema.parse("message A { } message A { }"));
    assertThrown!SchemaException(Schema.parse("message A { int32 x = 1; } // c"));
}
