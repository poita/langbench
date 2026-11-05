/**
 * The line-oriented command language: parses a whole input buffer and writes
 * one result per command to an `OutBuffer`.
 *
 * See the README for the command table. Malformed lines never throw; they
 * produce the single word `error`.
 */
module webhooks.commands;

import core.stdc.string : memchr;

import webhooks.base64;
import webhooks.buffer;
import webhooks.fields;
import webhooks.hex;
import webhooks.hmac;
import webhooks.secret;
import webhooks.sha256;
import webhooks.signature;
import webhooks.simulator;

/// Iterates over the lines of a buffer (split on LF; a final unterminated line counts).
struct LineReader
{
    private Bytes rest;

    this(Bytes input) @safe pure nothrow @nogc
    {
        rest = input;
    }

    /// Fetch the next line (without its LF). Returns `false` at end of input.
    bool next(out Bytes line) @trusted pure nothrow @nogc
    {
        if (rest.length == 0)
            return false;
        auto p = cast(const(ubyte)*) memchr(rest.ptr, '\n', rest.length);
        if (p is null)
        {
            line = rest;
            rest = rest[$ .. $];
        }
        else
        {
            immutable n = p - rest.ptr;
            line = rest[0 .. n];
            rest = rest[n + 1 .. $];
        }
        return true;
    }
}

/// Process every command in `input`, appending the results to `output`.
void processInput(Bytes input, ref OutBuffer output)
{
    auto reader = LineReader(input);
    Bytes line;
    Bytes[] storage;
    while (reader.next(line))
    {
        if (isBlank(line))
            continue;
        auto fields = splitOn(line, ' ', storage);
        if (fields.length == 1 && equalsString(fields[0], "simulate"))
        {
            runSimulateBlock(reader, output);
            continue;
        }
        if (!executeCommand(fields, output))
            output.put("error\n");
    }
}

/// Convenience wrapper: process `input` text and return the output as a string.
string processString(string input)
{
    OutBuffer o;
    processInput(asBytes(input), o);
    return o.toString();
}

private void runSimulateBlock(ref LineReader reader, ref OutBuffer output)
{
    SimulationBuilder builder;
    bool ended = false;
    Bytes line;
    while (reader.next(line))
    {
        if (isBlank(line))
            continue;
        if (builder.feed(line) == Feed.end)
        {
            ended = true;
            break;
        }
    }
    if (!ended || !builder.valid)
    {
        output.put("error\n");
        return;
    }
    run(builder.simulation, output);
}

/// Execute one single-line command given its fields. Returns false (writing nothing) on any error.
private bool executeCommand(Bytes[] f, ref OutBuffer output)
{
    foreach (x; f)
        if (x.length == 0)
            return false;
    Bytes name = f[0];

    bool isCmd(string n, size_t fieldCount)
    {
        return equalsString(name, n) && f.length == fieldCount;
    }

    if (isCmd("sha256", 2))
    {
        ubyte[] data;
        if (!decodeHex(f[1], data))
            return false;
        putHex(output, sha256(data)[]);
    }
    else if (isCmd("hmac", 3))
    {
        ubyte[] key, msg;
        if (!decodeHex(f[1], key) || !decodeHex(f[2], msg))
            return false;
        putHex(output, hmacSha256(key, msg)[]);
    }
    else if (isCmd("b64enc", 2) || isCmd("b64urlenc", 2))
    {
        ubyte[] data;
        if (!decodeHex(f[1], data))
            return false;
        if (data.length == 0)
            output.put("-");
        else if (equalsString(name, "b64enc"))
            putStandard(output, data);
        else
            putUrlSafe(output, data);
    }
    else if (isCmd("b64dec", 2))
    {
        ubyte[] text, decoded;
        if (!decodeHex(f[1], text) || !decode(text, decoded))
            return false;
        putHexOrDash(output, decoded);
    }
    else if (isCmd("secret", 2))
    {
        ubyte[] key;
        if (!decodeSecret(f[1], key))
            return false;
        putHex(output, key);
    }
    else if (isCmd("sign", 5))
    {
        HmacKey[] keys;
        long ts;
        ubyte[] payload;
        if (!parseSecrets(f[1], keys) || !isMessageId(f[2])
                || !parseCanonicalInt(f[3], ts) || !decodeHex(f[4], payload))
            return false;
        putSignatureHeader(output, keys, f[2], f[3], payload);
    }
    else if (isCmd("verify", 7))
    {
        HmacKey[] keys;
        long now;
        ubyte[] header, payload;
        if (!parseSecrets(f[1], keys) || !isMessageId(f[2]) || !isPrintableToken(f[3], 64)
                || !parseCanonicalInt(f[4], now) || !decodeHex(f[5], header)
                || !decodeHex(f[6], payload))
            return false;
        immutable r = verify(keys, f[2], f[3], now, header, payload);
        if (r.status == VerifyStatus.ok)
        {
            output.put("ok ");
            output.putInt(r.secretIndex);
            output.put(cast(ubyte) ' ');
            output.putInt(r.tokenIndex);
        }
        else
        {
            output.put("fail ");
            output.put(reason(r.status));
        }
    }
    else
        return false;
    output.put(cast(ubyte) '\n');
    return true;
}
