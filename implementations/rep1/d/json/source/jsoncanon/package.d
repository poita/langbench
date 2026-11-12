/**
 * jsoncanon: a strict RFC 8259 JSON parser and a canonical serializer.
 *
 * The library is split by responsibility:
 *
 * $(UL
 *   $(LI $(MREF jsoncanon, utf8)       – strict UTF-8 validation and encoding)
 *   $(LI $(MREF jsoncanon, value)      – the parsed document tree)
 *   $(LI $(MREF jsoncanon, parser)     – recursive-descent parser)
 *   $(LI $(MREF jsoncanon, order)      – UTF-16 code unit ordering of UTF-8 keys)
 *   $(LI $(MREF jsoncanon, serializer) – canonical output)
 * )
 *
 * Importing `jsoncanon` gives access to all of them.
 *
 * Example:
 * ---
 * import jsoncanon;
 *
 * assert(canonicalize(`{ "b": [1, 2.50, 1E+3], "a": "x", "b": null }`)
 *        == `{"a":"x","b":null}`);
 * ---
 */
module jsoncanon;

public import jsoncanon.utf8;
public import jsoncanon.value;
public import jsoncanon.parser;
public import jsoncanon.order;
public import jsoncanon.serializer;


/**
 * Parses `input` and returns its canonical serialization (without a trailing
 * newline).
 *
 * Throws: $(REF JsonException, jsoncanon, parser) if the input is not a valid
 * document.
 */
string canonicalize(scope const(char)[] input) @safe
{
    return canonicalize(cast(const(ubyte)[]) input);
}

/// ditto
string canonicalize(scope const(ubyte)[] input) @safe
{
    return toCanonical(parse(input));
}

/**
 * Like $(LREF canonicalize) but returns `false` instead of throwing when the
 * input is invalid.
 */
bool tryCanonicalize(scope const(ubyte)[] input, out string result) @safe
{
    JsonValue v;
    if (!tryParse(input, v))
        return false;
    result = toCanonical(v);
    return true;
}

@safe unittest
{
    assert(canonicalize(`[1, 2.50, 1E+3]`) == `[1,2.50,1e3]`);
    string r;
    assert(!tryCanonicalize(cast(const(ubyte)[]) "[1,]", r));
    assert(tryCanonicalize(cast(const(ubyte)[]) " null ", r) && r == "null");
}
