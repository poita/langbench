/**
 * The parsed document tree.
 */
module jsoncanon.value;

/// The kind of a $(LREF JsonValue).
enum JsonKind : ubyte
{
    null_,
    false_,
    true_,
    /// A number, stored as its canonical text (see $(MREF jsoncanon, parser)).
    number,
    /// A string, stored decoded as UTF-8.
    string_,
    array,
    object,
}

/// One `key: value` entry of an object.
struct JsonMember
{
    /// The decoded key (UTF-8).
    string key;
    /// The member's value.
    JsonValue value;
}

/**
 * A JSON value.
 *
 * Numbers are never converted to floating point: they keep their (exponent
 * normalised) decimal text. Objects keep every member, duplicates included,
 * in input order; deduplication and ordering happen at serialization time.
 */
struct JsonValue
{
    /// Kind of value held.
    JsonKind kind;

    private
    {
        union
        {
            string _text;
            JsonValue[] _items;
            JsonMember[] _members;
        }
    }

    /// Constructors for each kind.
    static JsonValue makeNull() @safe pure nothrow @nogc
    {
        return JsonValue.init;
    }

    /// ditto
    static JsonValue makeBool(bool b) @safe pure nothrow @nogc
    {
        JsonValue v;
        v.kind = b ? JsonKind.true_ : JsonKind.false_;
        return v;
    }

    /// ditto
    static JsonValue makeNumber(string canonicalText) @trusted pure nothrow @nogc
    {
        JsonValue v;
        v.kind = JsonKind.number;
        v._text = canonicalText;
        return v;
    }

    /// ditto
    static JsonValue makeString(string decoded) @trusted pure nothrow @nogc
    {
        JsonValue v;
        v.kind = JsonKind.string_;
        v._text = decoded;
        return v;
    }

    /// ditto
    static JsonValue makeArray(JsonValue[] items) @trusted pure nothrow @nogc
    {
        JsonValue v;
        v.kind = JsonKind.array;
        v._items = items;
        return v;
    }

    /// ditto
    static JsonValue makeObject(JsonMember[] members) @trusted pure nothrow @nogc
    {
        JsonValue v;
        v.kind = JsonKind.object;
        v._members = members;
        return v;
    }

    /// Number text or string contents. Only valid for numbers and strings.
    @property string text() const @trusted pure nothrow @nogc
    in (kind == JsonKind.number || kind == JsonKind.string_)
    {
        return _text;
    }

    /// Elements of an array. Only valid for arrays.
    @property inout(JsonValue)[] items() inout @trusted pure nothrow @nogc
    in (kind == JsonKind.array)
    {
        return _items;
    }

    /// Members of an object in input order, duplicates included.
    @property inout(JsonMember)[] members() inout @trusted pure nothrow @nogc
    in (kind == JsonKind.object)
    {
        return _members;
    }
}

@safe unittest
{
    auto a = JsonValue.makeArray([JsonValue.makeNumber("1"), JsonValue.makeBool(true),
            JsonValue.makeNull()]);
    assert(a.kind == JsonKind.array && a.items.length == 3);
    assert(a.items[0].text == "1");
    assert(a.items[1].kind == JsonKind.true_);
    assert(a.items[2].kind == JsonKind.null_);

    auto o = JsonValue.makeObject([JsonMember("k", JsonValue.makeString("v"))]);
    assert(o.members[0].key == "k" && o.members[0].value.text == "v");
}
