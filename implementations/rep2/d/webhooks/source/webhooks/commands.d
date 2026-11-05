/**
 * The line-oriented command protocol: parses commands, runs them against the
 * library, and renders the output.
 */
module webhooks.commands;

import webhooks.base64;
import webhooks.grammar;
import webhooks.hex;
import webhooks.hmac;
import webhooks.outbuf;
import webhooks.secret;
import webhooks.sha256;
import webhooks.signature;
import webhooks.simparse;
import webhooks.simulator;

/**
 * Executes every command in `input` and appends the results to `output`.
 *
 * Never throws for malformed input: a bad command line prints `error`.
 * `input` must stay alive and unchanged for the duration of the call.
 */
void processInput(scope const(ubyte)[] input, ref OutBuf output) @trusted
{
    auto session = Session(input, &output);
    session.run();
}

private struct Session
{
    const(ubyte)[] input;
    OutBuf* output;
    size_t pos;

    /// Next non-blank line (without its `\n`), or false at end of input.
    bool nextLine(out const(ubyte)[] line) @safe pure nothrow @nogc
    {
        while (pos < input.length)
        {
            size_t end = pos;
            while (end < input.length && input[end] != '\n')
                end++;
            auto candidate = input[pos .. end];
            pos = end < input.length ? end + 1 : end;
            if (!isBlank(candidate))
            {
                line = candidate;
                return true;
            }
        }
        return false;
    }

    void run() @safe
    {
        const(ubyte)[] line;
        while (nextLine(line))
        {
            auto f = splitFields(line);
            if (!dispatch(f))
                output.put("error\n");
        }
    }

    /// Runs one command line; false means the line is an `error`.
    bool dispatch(ref const Fields f) @safe
    {
        if (f.anyEmpty || f.count == 0)
            return false;
        auto name = cast(const(char)[]) f.item[0];
        switch (name)
        {
        case "sha256":
            return cmdSha256(f);
        case "hmac":
            return cmdHmac(f);
        case "b64enc":
            return cmdB64enc(f, false);
        case "b64urlenc":
            return cmdB64enc(f, true);
        case "b64dec":
            return cmdB64dec(f);
        case "secret":
            return cmdSecret(f);
        case "sign":
            return cmdSign(f);
        case "verify":
            return cmdVerify(f);
        case "simulate":
            return cmdSimulate(f);
        default:
            return false;
        }
    }

    /// Prints hex, or `-` if there are no bytes.
    void putHexOrDash(scope const(ubyte)[] bytes) @safe
    {
        if (bytes.length == 0)
            output.putByte('-');
        else
            output.putHex(bytes);
        output.putByte('\n');
    }

    bool cmdSha256(ref const Fields f) @safe
    {
        ubyte[] data;
        if (!f.has(2) || !decodeHex(f.item[1], data))
            return false;
        putHexOrDash(sha256Of(data)[]);
        return true;
    }

    bool cmdHmac(ref const Fields f) @safe
    {
        ubyte[] key, msg;
        if (!f.has(3) || !decodeHex(f.item[1], key) || !decodeHex(f.item[2], msg))
            return false;
        putHexOrDash(hmacSha256(key, msg)[]);
        return true;
    }

    bool cmdB64enc(ref const Fields f, bool url) @safe
    {
        ubyte[] data;
        if (!f.has(2) || !decodeHex(f.item[1], data))
            return false;
        if (data.length == 0)
            output.putByte('-');
        else if (url)
            appendEncodedUrl(*output, data);
        else
            appendEncoded(*output, data);
        output.putByte('\n');
        return true;
    }

    bool cmdB64dec(ref const Fields f) @safe
    {
        ubyte[] text, bytes;
        if (!f.has(2) || !decodeHex(f.item[1], text) || !decode(text, bytes))
            return false;
        putHexOrDash(bytes);
        return true;
    }

    bool cmdSecret(ref const Fields f) @safe
    {
        ubyte[] key;
        if (!f.has(2) || !parseSecretField(f.item[1], key))
            return false;
        putHexOrDash(key);
        return true;
    }

    bool cmdSign(ref const Fields f) @safe
    {
        HmacKey[] keys;
        long ts;
        ubyte[] payload;
        if (!f.has(5) || !parseSecretList(f.item[1], keys)
            || !isPrintableToken(f.item[2], 256)
            || !parseCanonicalInt(f.item[3], ts) || !decodeHex(f.item[4], payload))
            return false;
        appendSignatureHeader(*output, keys, f.item[2], f.item[3], payload);
        output.putByte('\n');
        return true;
    }

    bool cmdVerify(ref const Fields f) @safe
    {
        HmacKey[] keys;
        long now;
        ubyte[] header, payload;
        if (!f.has(7) || !parseSecretList(f.item[1], keys)
            || !isPrintableToken(f.item[2], 256)
            || !isPrintableToken(f.item[3], 64)
            || !parseCanonicalInt(f.item[4], now)
            || !decodeHex(f.item[5], header) || !decodeHex(f.item[6], payload))
            return false;
        immutable r = verify(keys, f.item[2], f.item[3], header, payload, now);
        if (r.ok)
        {
            output.put("ok ");
            output.putInt(r.secretIndex);
            output.putByte(' ');
            output.putInt(r.tokenIndex);
        }
        else
        {
            output.put("fail ");
            output.put(statusName(r.status));
        }
        output.putByte('\n');
        return true;
    }

    bool cmdSimulate(ref const Fields f) @safe
    {
        if (!f.has(1))
            return false;
        BlockBuilder builder;
        bool valid = true;
        const(ubyte)[] line;
        bool closed = false;
        while (nextLine(line))
        {
            if (equals(line, "end"))
            {
                closed = true;
                break;
            }
            if (!valid)
                continue; // only looking for `end`
            auto bf = splitFields(line);
            if (bf.isCommand("endpoint"))
                valid = builder.addEndpoint(bf);
            else if (bf.isCommand("event"))
                valid = builder.addEvent(bf);
            else
                valid = false;
        }
        if (!closed || !valid || builder.endpointCount == 0)
            return false;
        auto report = builder.build().run();
        report.write(*output);
        return true;
    }
}
