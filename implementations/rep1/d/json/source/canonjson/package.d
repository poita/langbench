/**
 * canonjson: a strict JSON parser and canonical serializer.
 *
 * Reads one RFC 8259 document, validating every byte (including strict UTF-8),
 * and writes it in canonical form: no insignificant whitespace, object keys
 * deduplicated (last wins) and sorted in UTF-16 code unit order, minimal
 * string escapes, and numbers echoed textually with a normalised exponent.
 *
 * ---
 * import canonjson;
 * assert(canonicalize(`{ "b": [1, 2.50, 1E+3], "a": "x", "b": null }`)
 *        == `{"a":"x","b":null}`);
 * ---
 *
 * Modules:
 * $(UL
 *   $(LI `canonjson.parser`: `parse`, `tryParse`, `ParseException`)
 *   $(LI `canonjson.value`: the `Value` tree)
 *   $(LI `canonjson.serializer`: `serialize`, `toCanonical`, `writeString`)
 *   $(LI `canonjson.keyorder`: `compareKeys`)
 *   $(LI `canonjson.utf8`: `validateUtf8`)
 *   $(LI `canonjson.buffer`: `ByteBuffer`)
 * )
 */
module canonjson;

public import canonjson.buffer;
public import canonjson.keyorder;
public import canonjson.parser;
public import canonjson.serializer;
public import canonjson.utf8 : validateUtf8, hasByteOrderMark;
public import canonjson.value;

/**
 * Parses `input` and returns its canonical form (without a trailing newline).
 *
 * Throws: $(REF ParseException, canonjson,parser) if `input` is not valid.
 */
ubyte[] canonicalize(const(ubyte)[] input) @safe
{
    auto v = parse(input);
    ByteBuffer buf = ByteBuffer(input.length + 16);
    serialize(v, buf);
    return buf.data.dup;
}

/// ditto
string canonicalize(const(char)[] input) @trusted
{
    return cast(string) canonicalize(cast(const(ubyte)[]) input);
}

/// Like `canonicalize` but returns false (leaving `output` empty) when `input` is invalid.
bool tryCanonicalize(const(ubyte)[] input, out ubyte[] output) @safe
{
    try
    {
        output = canonicalize(input);
        return true;
    }
    catch (ParseException)
        return false;
}
