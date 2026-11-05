/**
 * The in-memory document tree.
 *
 * A $(LREF Value) is a small tagged union. Strings and numbers are slices of
 * bytes: when the document was parsed from a buffer, escape-free strings and
 * plain numbers $(I borrow) from that buffer, so the input must outlive the tree.
 */
module canonjson.value;

/// The type of a $(LREF Value).
enum Kind : ubyte
{
    null_,
    false_,
    true_,
    number,
    string,
    array,
    object,
}

/// One `key: value` entry of an object, in input order.
struct Member
{
    /// Decoded key, valid UTF-8 bytes.
    const(ubyte)[] key;
    /// The member's value.
    Value value;
}

/// A JSON value.
struct Value
{
    private Kind kind_;
    private union
    {
        const(ubyte)[] text_;
        Value[] items_;
        Member[] members_;
    }

    /// The value's type.
    Kind kind() const @safe pure nothrow @nogc { return kind_; }

    /// Makes `null`, `true` or `false`.
    static Value literal(Kind k) @safe pure nothrow @nogc
    in (k == Kind.null_ || k == Kind.false_ || k == Kind.true_)
    {
        Value v;
        v.kind_ = k;
        return v;
    }

    /// Makes a string from decoded, valid UTF-8 bytes.
    static Value makeString(const(ubyte)[] utf8) @trusted pure nothrow @nogc
    {
        Value v;
        v.kind_ = Kind.string;
        v.text_ = utf8;
        return v;
    }

    /// Makes a number from its canonical text (see the serializer; this is not validated).
    static Value makeNumber(const(ubyte)[] canonicalText) @trusted pure nothrow @nogc
    {
        Value v;
        v.kind_ = Kind.number;
        v.text_ = canonicalText;
        return v;
    }

    /// Makes an array.
    static Value makeArray(Value[] elements) @trusted pure nothrow @nogc
    {
        Value v;
        v.kind_ = Kind.array;
        v.items_ = elements;
        return v;
    }

    /// Makes an object. Members may contain duplicate keys and are in any order;
    /// the serializer sorts and deduplicates.
    static Value makeObject(Member[] members) @trusted pure nothrow @nogc
    {
        Value v;
        v.kind_ = Kind.object;
        v.members_ = members;
        return v;
    }

    /// Decoded UTF-8 bytes of a string value.
    const(ubyte)[] stringBytes() const @trusted pure nothrow @nogc
    in (kind_ == Kind.string)
    {
        return text_;
    }

    /// The string value as a D string (copies).
    string str() const @trusted pure nothrow
    in (kind_ == Kind.string)
    {
        return (cast(const(char)[]) text_).idup;
    }

    /// Canonical text of a number value.
    const(ubyte)[] numberText() const @trusted pure nothrow @nogc
    in (kind_ == Kind.number)
    {
        return text_;
    }

    /// Elements of an array value.
    inout(Value)[] array() inout @trusted pure nothrow @nogc
    in (kind_ == Kind.array)
    {
        return items_;
    }

    /// Members of an object value in input order (duplicates included).
    inout(Member)[] object() inout @trusted pure nothrow @nogc
    in (kind_ == Kind.object)
    {
        return members_;
    }
}
