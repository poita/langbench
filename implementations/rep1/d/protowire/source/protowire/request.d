/// The line-oriented request protocol used by the command-line tool.
///
/// Input is a schema, a line `--`, then one request per line:
/// ---
/// decode <Name> <hex>
/// encode <Name> <text>
/// ---
/// Each request yields one output line: the result, or `error`.
module protowire.request;

import std.array : Appender;
import protowire.codec;
import protowire.errors;
import protowire.hex : appendHex, fromHex;
import protowire.schema : Schema;
import protowire.textformat : CharBuffer, formatMessageTo, parseMessage;
import protowire.decoder : decodeMessage;
import protowire.encoder : encodeMessage;

/// Executes one request line against `schema` and returns its result line
/// (without the trailing newline). Throws a `ProtowireException` if the
/// request is malformed or fails.
string executeRequest(Schema schema, scope const(char)[] line) @safe
{
    auto sink = CharBuffer();
    executeRequestTo(sink, schema, line);
    return (() @trusted => cast(string) sink.data)();
}

/// Like `executeRequest`, appending the result to `sink`. If it throws,
/// `sink` is left unchanged.
void executeRequestTo(ref CharBuffer sink, Schema schema, scope const(char)[] line) @safe
{
    bool isDecode;
    if (line.length >= 7 && line[0 .. 7] == "decode ")
        isDecode = true;
    else if (line.length >= 7 && line[0 .. 7] == "encode ")
        isDecode = false;
    else
        throw new RequestException("unknown request");

    auto rest = line[7 .. $];
    size_t nameEnd = 0;
    while (nameEnd < rest.length && rest[nameEnd] != ' ')
        ++nameEnd;
    auto desc = schema.find(rest[0 .. nameEnd]);
    if (desc is null)
        throw new RequestException("unknown message");
    rest = rest[nameEnd .. $];

    if (isDecode)
    {
        // Either nothing at all, or a single space followed by a non-empty hex string.
        if (rest.length == 0)
        {
            formatMessageTo(sink, decodeMessage(desc, null));
            return;
        }
        if (rest.length == 1)
            throw new RequestException("empty hex after separator");
        formatMessageTo(sink, decodeMessage(desc, fromHex(rest[1 .. $])));
    }
    else
    {
        // A single space, then the text (which may itself begin with spaces).
        if (rest.length == 0)
            throw new RequestException("missing text");
        auto bytes = encodeMessage(parseMessage(desc, rest[1 .. $]));
        appendHex(sink, bytes);
    }
}

/// Processes a complete input document (schema, `--`, requests) and returns
/// the complete output: one line per request, `error` for each failed
/// request. Throws `SchemaException` if the schema cannot be parsed.
char[] processInput(const(char)[] input) @safe
{
    // The schema is everything before the first line that is exactly "--".
    size_t pos = 0;
    size_t schemaEnd = input.length;
    size_t requestsStart = input.length;
    while (pos <= input.length)
    {
        size_t eol = pos;
        while (eol < input.length && input[eol] != '\n')
            ++eol;
        if (input[pos .. eol] == "--")
        {
            schemaEnd = pos;
            requestsStart = eol < input.length ? eol + 1 : eol;
            break;
        }
        if (eol >= input.length)
            break;
        pos = eol + 1;
    }
    auto schema = Schema.parse(input[0 .. schemaEnd]);

    auto sink = CharBuffer();
    sink.reserve(input.length - requestsStart + 16);
    pos = requestsStart;
    while (pos < input.length)
    {
        size_t eol = pos;
        while (eol < input.length && input[eol] != '\n')
            ++eol;
        immutable mark = sink.data.length;
        try
            executeRequestTo(sink, schema, input[pos .. eol]);
        catch (Exception)
        {
            sink.shrinkTo(mark);
            sink.put("error");
        }
        sink.put('\n');
        pos = eol + 1;
    }
    return sink.data;
}

@safe unittest
{
    import std.exception : assertThrown;

    auto s = Schema.parse("message M { uint64 u = 1; bytes y = 4; }");
    assert(executeRequest(s, "decode M") == "{}");
    assert(executeRequest(s, "encode M {u: 5}") == "0805");
    assert(executeRequest(s, "encode M   {u: 5}  ") == "0805");
    assertThrown!ProtowireException(executeRequest(s, "decode M "));
    assertThrown!ProtowireException(executeRequest(s, "decode M 0A"));
    assertThrown!ProtowireException(executeRequest(s, "decode M 08 01"));
    assertThrown!ProtowireException(executeRequest(s, "decode M 080"));
    assertThrown!ProtowireException(executeRequest(s, "encode M"));
    assertThrown!ProtowireException(executeRequest(s, "encode M "));
    assertThrown!ProtowireException(executeRequest(s, "encode Nope {}"));
    assertThrown!ProtowireException(executeRequest(s, "frobnicate M"));
}

@safe unittest
{
    // The first worked example of the specification.
    immutable input = "message Inner { sint32 v = 1; }\n"
        ~ "message Outer {\n  int32 a = 1;\n  string b = 2;\n  repeated int32 c = 3;\n  Inner d = 4;\n}\n"
        ~ "--\n"
        ~ "encode Outer {a: 1, b: \"x\", c: [1, 2], d: {v: -5}}\n"
        ~ "decode Outer 08011201781a02010222020809\n"
        ~ "encode Outer {d: {}, c: [], a: 0}\n"
        ~ "decode Outer 3800\n"
        ~ "decode Outer 08ff";
    assert(processInput(input) == "08011201781a02010222020809\n"
            ~ "{a: 1, b: \"x\", c: [1, 2], d: {v: -5}}\n2200\n{}\nerror\n");
    // an empty encoding gives an empty line
    assert(processInput("message M { int32 a = 1; }\n--\nencode M {}\n") == "\n");
}
