/**
 * The line-oriented request protocol: a schema, a `--` line, then one
 * `decode`/`encode` request per line. Each request yields one output line.
 */
module protowire.session;

import core.stdc.string : memchr;

import protowire.codec;
import protowire.hex;
import protowire.memory;
import protowire.schema;

/**
 * Process a whole input document and append the output lines to `output`.
 *
 * A malformed request produces the line `error`. If the schema itself cannot
 * be parsed every request is an `error`.
 */
void processDocument(const(ubyte)[] input, ref ByteBuffer output)
{
    // Locate the separator: the first line consisting exactly of "--".
    size_t schemaEnd = input.length;
    size_t reqStart = input.length;
    for (size_t ls = 0; ls < input.length;)
    {
        const le = lineEnd(input, ls);
        if (le - ls == 2 && input[ls] == '-' && input[ls + 1] == '-')
        {
            schemaEnd = ls;
            reqStart = le < input.length ? le + 1 : le;
            break;
        }
        ls = le + 1;
    }

    Codec codec;
    try
        codec = new Codec(Schema.parse((cast(const(char)[]) input[0 .. schemaEnd]).idup));
    catch (SchemaException)
        codec = null;

    ByteBuffer scratch;
    for (size_t ls = reqStart; ls < input.length;)
    {
        const le = lineEnd(input, ls);
        const mark = output.length;
        if (codec is null || !processRequest(codec, input[ls .. le], output, scratch))
        {
            output.truncate(mark);
            output.putString("error");
        }
        output.putByte('\n');
        ls = le + 1;
    }
}

/**
 * Process one request line (without its newline), appending the result (but
 * no newline) to `output`. Returns false for a malformed request.
 */
bool processRequest(Codec codec, const(ubyte)[] line, ref ByteBuffer output,
        ref ByteBuffer scratch)
{
    enum prefixLen = 7; // "decode " / "encode "
    if (line.length < prefixLen)
        return false;
    const cmd = cast(const(char)[]) line[0 .. prefixLen];
    const isDecode = cmd == "decode ";
    if (!isDecode && cmd != "encode ")
        return false;

    const rest = line[prefixLen .. $];
    size_t n = 0;
    while (n < rest.length && rest[n] != ' ')
        n++;
    const msg = codec.schema.messageIndex(cast(const(char)[]) rest[0 .. n]);
    if (msg < 0)
        return false;
    const hasArg = n < rest.length;
    const arg = hasArg ? rest[n + 1 .. $] : rest[n .. $];

    scratch.clear();
    if (isDecode)
    {
        if (hasArg && arg.length == 0)
            return false; // trailing space
        if (!hexDecode(arg, scratch))
            return false;
        return codec.decodeToText(msg, scratch.data, output);
    }
    if (!hasArg)
        return false;
    if (!codec.encodeFromText(msg, arg, scratch))
        return false;
    output.putHex(scratch.data);
    return true;
}

private size_t lineEnd(const(ubyte)[] s, size_t from) nothrow @nogc @trusted
{
    auto p = cast(const(ubyte)*) memchr(s.ptr + from, '\n', s.length - from);
    return p is null ? s.length : cast(size_t)(p - s.ptr);
}
