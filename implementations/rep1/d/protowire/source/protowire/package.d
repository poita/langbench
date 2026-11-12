/**
 * protowire: a Protocol Buffers style wire codec with proto3 semantics.
 *
 * Parse a schema, then convert between the binary wire format, hex and a
 * canonical text form:
 *
 * ---
 * import protowire;
 *
 * auto schema = Schema.parse("message P { int32 a = 1; repeated int32 c = 3; }");
 * auto p = schema["P"];
 * assert(encodeTextToHex(p, "{c: [1, 2], a: 1}") == "08011a02" ~ "0102");
 * assert(decodeHexToText(p, "08011a020102") == "{a: 1, c: [1, 2]}");
 * ---
 *
 * Modules:
 * $(UL
 *  $(LI `protowire.schema`: schema text -> `MessageDescriptor`s)
 *  $(LI `protowire.wire`: varints, tags, zigzag, bounds-checked `Reader`)
 *  $(LI `protowire.value`: the `Message` value tree)
 *  $(LI `protowire.decoder`: bytes -> `Message`)
 *  $(LI `protowire.encoder`: `Message` -> canonical bytes)
 *  $(LI `protowire.textformat`: `Message` <-> canonical text)
 *  $(LI `protowire.codec`: one-call conversions)
 *  $(LI `protowire.request`: the request-line protocol of the CLI)
 *  $(LI `protowire.hex`, `protowire.utf8`, `protowire.errors`: helpers))
 */
module protowire;

public import protowire.codec;
public import protowire.decoder : decodeMessage;
public import protowire.encoder : encodeMessage;
public import protowire.errors;
public import protowire.hex;
public import protowire.request;
public import protowire.schema;
public import protowire.textformat : formatMessage, formatMessageTo, parseMessage, CharBuffer;
public import protowire.utf8;
public import protowire.value;
public import protowire.wire;

@safe unittest
{
    auto schema = Schema.parse("message P { int32 a = 1; repeated int32 c = 3; }");
    auto p = schema["P"];
    assert(encodeTextToHex(p, "{c: [1, 2], a: 1}") == "08011a020102");
    assert(decodeHexToText(p, "08011a020102") == "{a: 1, c: [1, 2]}");
}
