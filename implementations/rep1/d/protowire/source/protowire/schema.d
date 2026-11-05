/**
 * Message schemas: parsing the schema language and the compiled descriptors
 * used by the decoder and encoder.
 */
module protowire.schema;

import std.algorithm.sorting : sort;

import protowire.wire : WireType, varintLength;

/// Field types.
enum Kind : ubyte
{
    int32,
    int64,
    uint32,
    uint64,
    sint32,
    sint64,
    boolean,
    fixed32,
    fixed64,
    sfixed32,
    sfixed64,
    text, /// `string`
    bytes,
    message,
}

/// Thrown by $(LREF Schema.parse) when the schema text is malformed.
class SchemaException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// Whether values of `k` are numbers (everything except text, bytes, message).
bool isNumeric(Kind k) pure nothrow @nogc @safe
{
    return k < Kind.text;
}

/// Whether values of `k` print as signed decimal integers.
bool isSigned(Kind k) pure nothrow @nogc @safe
{
    final switch (k)
    {
    case Kind.int32, Kind.int64, Kind.sint32, Kind.sint64, Kind.sfixed32, Kind.sfixed64:
        return true;
    case Kind.uint32, Kind.uint64, Kind.boolean, Kind.fixed32, Kind.fixed64,
            Kind.text, Kind.bytes, Kind.message:
        return false;
    }
}

/// The wire type used by a (non-packed) value of type `k`.
WireType wireTypeOf(Kind k) pure nothrow @nogc @safe
{
    final switch (k)
    {
    case Kind.int32, Kind.int64, Kind.uint32, Kind.uint64, Kind.sint32,
            Kind.sint64, Kind.boolean:
        return WireType.varint;
    case Kind.fixed32, Kind.sfixed32:
        return WireType.fixed32;
    case Kind.fixed64, Kind.sfixed64:
        return WireType.fixed64;
    case Kind.text, Kind.bytes, Kind.message:
        return WireType.lengthDelimited;
    }
}

/// One field of a message, with everything the codec needs precomputed.
struct Field
{
    /// Field name.
    string name;
    /// Field number.
    uint number;
    /// Value type.
    Kind kind;
    /// Declared `repeated`.
    bool repeated;
    /// Index into `Schema.messages` for message-typed fields, else -1.
    int message = -1;
    /// Wire type of one (unpacked) value.
    WireType wireType;
    /// `(number << 3) | wireType` for the field's own wire type.
    ulong tag;
    /// Byte length of the tag when encoded for the field's own wire type.
    ubyte tagLen;
    /// Tag for a packed payload (wire type 2).
    ulong packedTag;
    /// Byte length of `packedTag`.
    ubyte packedTagLen;
}

/// A compiled message descriptor. `fields` is sorted by field number.
struct Message
{
    /// Message name.
    string name;
    /// Fields in increasing field-number order.
    Field[] fields;
    private uint[] numbers;
    private int[string] byName;

    /// Index in `fields` of the field with this number, or -1.
    int findNumber(uint number) const pure nothrow @nogc @trusted
    {
        const(uint)* a = numbers.ptr;
        size_t lo = 0, hi = numbers.length;
        while (lo < hi)
        {
            const mid = (lo + hi) >> 1;
            const v = a[mid];
            if (v == number)
                return cast(int) mid;
            if (v < number)
                lo = mid + 1;
            else
                hi = mid;
        }
        return -1;
    }

    /// Index in `fields` of the field with this name, or -1.
    int findName(const(char)[] fieldName) const nothrow @trusted
    {
        if (auto p = cast(string) fieldName in byName)
            return *p;
        return -1;
    }
}

/**
 * A parsed schema: a list of messages, resolved and ready for use by
 * $(REF Codec, protowire,codec).
 */
final class Schema
{
    /// All messages, in declaration order.
    Message[] messages;
    private int[string] index;

    /// Index of the message called `name`, or -1.
    int messageIndex(const(char)[] name) const nothrow @trusted
    {
        if (auto p = cast(string) name in index)
            return *p;
        return -1;
    }

    /**
     * Parse schema text such as `message A { int32 x = 1; repeated A kids = 2; }`.
     *
     * Throws: $(LREF SchemaException) if the text is not a valid schema.
     */
    static Schema parse(string text) @safe
    {
        auto s = new Schema;
        s.build(tokenize(text));
        return s;
    }

    private void build(string[] toks) @safe
    {
        // Pass 1: collect message names so types may refer forward.
        foreach (i, t; toks)
        {
            if (t == "message")
            {
                if (i + 1 >= toks.length)
                    throw new SchemaException("message name expected");
                const name = toks[i + 1];
                if (!isIdentifier(name))
                    throw new SchemaException("bad message name: " ~ name);
                if (name in index)
                    throw new SchemaException("duplicate message: " ~ name);
                index[name] = cast(int) messages.length;
                messages ~= Message(name);
            }
        }

        // Pass 2: parse the bodies.
        size_t pos = 0;
        size_t msgNo = 0;
        string next()
        {
            if (pos >= toks.length)
                throw new SchemaException("unexpected end of schema");
            return toks[pos++];
        }
        void expect(string want)
        {
            const got = next();
            if (got != want)
                throw new SchemaException("expected '" ~ want ~ "', got '" ~ got ~ "'");
        }

        while (pos < toks.length)
        {
            expect("message");
            next(); // name, already registered
            expect("{");
            Message* m = &messages[msgNo++];
            while (true)
            {
                string t = next();
                if (t == "}")
                    break;
                Field f;
                if (t == "repeated")
                {
                    f.repeated = true;
                    t = next();
                }
                Kind k;
                if (scalarKind(t, k))
                    f.kind = k;
                else if (auto p = t in index)
                {
                    f.kind = Kind.message;
                    f.message = *p;
                }
                else
                    throw new SchemaException("unknown type: " ~ t);
                f.name = next();
                if (!isIdentifier(f.name))
                    throw new SchemaException("bad field name: " ~ f.name);
                expect("=");
                f.number = parseFieldNumber(next());
                expect(";");
                f.wireType = wireTypeOf(f.kind);
                f.tag = (cast(ulong) f.number << 3) | f.wireType;
                f.tagLen = cast(ubyte) varintLength(f.tag);
                f.packedTag = (cast(ulong) f.number << 3) | WireType.lengthDelimited;
                f.packedTagLen = cast(ubyte) varintLength(f.packedTag);
                m.fields ~= f;
            }
            finish(*m);
        }
    }

    private static void finish(ref Message m) @safe
    {
        if (m.fields.length > 64)
            throw new SchemaException("too many fields in " ~ m.name);
        m.fields.sort!((a, b) => a.number < b.number);
        m.numbers = null;
        foreach (i, ref f; m.fields)
        {
            if (i > 0 && m.fields[i - 1].number == f.number)
                throw new SchemaException("duplicate field number in " ~ m.name);
            if (f.name in m.byName)
                throw new SchemaException("duplicate field name in " ~ m.name);
            m.numbers ~= f.number;
            m.byName[f.name] = cast(int) i;
        }
    }
}

private:

bool isIdentChar(char c) pure nothrow @nogc @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

bool isIdentifier(string s) pure nothrow @nogc @safe
{
    if (s.length == 0 || (s[0] >= '0' && s[0] <= '9'))
        return false;
    foreach (c; s)
        if (!isIdentChar(c))
            return false;
    return true;
}

string[] tokenize(string text) pure @safe
{
    string[] toks;
    size_t i = 0;
    while (i < text.length)
    {
        const c = text[i];
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
            i++;
        else if (c == '{' || c == '}' || c == ';' || c == '=')
        {
            toks ~= text[i .. i + 1];
            i++;
        }
        else if (isIdentChar(c))
        {
            const start = i;
            while (i < text.length && isIdentChar(text[i]))
                i++;
            toks ~= text[start .. i];
        }
        else
            throw new SchemaException("unexpected character in schema");
    }
    return toks;
}

uint parseFieldNumber(string s) pure @safe
{
    if (s.length == 0 || s.length > 9)
        throw new SchemaException("bad field number: " ~ s);
    uint v = 0;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            throw new SchemaException("bad field number: " ~ s);
        v = v * 10 + (c - '0');
    }
    if (v < 1 || v > 536_870_911)
        throw new SchemaException("field number out of range: " ~ s);
    return v;
}

bool scalarKind(string name, out Kind k) pure nothrow @nogc @safe
{
    switch (name)
    {
    case "int32":    k = Kind.int32; return true;
    case "int64":    k = Kind.int64; return true;
    case "uint32":   k = Kind.uint32; return true;
    case "uint64":   k = Kind.uint64; return true;
    case "sint32":   k = Kind.sint32; return true;
    case "sint64":   k = Kind.sint64; return true;
    case "bool":     k = Kind.boolean; return true;
    case "fixed32":  k = Kind.fixed32; return true;
    case "fixed64":  k = Kind.fixed64; return true;
    case "sfixed32": k = Kind.sfixed32; return true;
    case "sfixed64": k = Kind.sfixed64; return true;
    case "string":   k = Kind.text; return true;
    case "bytes":    k = Kind.bytes; return true;
    default:         return false;
    }
}
