/**
 * The command-stream interpreter: parses stdin-style input and writes the
 * results (one line per command, `simulate` blocks expand to several).
 */
module webhooks.commands;

import webhooks.base64;
import webhooks.buffer;
import webhooks.grammar;
import webhooks.hex;
import webhooks.hmac;
import webhooks.sha256;
import webhooks.signature;
import webhooks.simparse;
import webhooks.simulator;

private bool cmdSha256(ref const Fields f, ref ByteSink out_)
{
    if (f.count != 2)
        return false;
    ubyte[] data;
    if (!decodeHexArg(f[1], data))
        return false;
    encodeHex(sha256Of(data)[], out_);
    return true;
}

private bool cmdHmac(ref const Fields f, ref ByteSink out_)
{
    if (f.count != 3)
        return false;
    ubyte[] key, msg;
    if (!decodeHexArg(f[1], key) || !decodeHexArg(f[2], msg))
        return false;
    encodeHex(hmacSha256(key, msg)[], out_);
    return true;
}

private bool cmdEncode(ref const Fields f, ref ByteSink out_, bool urlSafe)
{
    if (f.count != 2)
        return false;
    ubyte[] data;
    if (!decodeHexArg(f[1], data))
        return false;
    if (data.length == 0)
    {
        out_.putChar('-');
        return true;
    }
    if (urlSafe)
        encodeUrlSafe(data, out_);
    else
        encodeStandard(data, out_);
    return true;
}

private bool cmdB64Dec(ref const Fields f, ref ByteSink out_)
{
    if (f.count != 2)
        return false;
    ubyte[] text, decoded;
    if (!decodeHexArg(f[1], text) || !decode(text, decoded))
        return false;
    encodeHexArg(decoded, out_);
    return true;
}

private bool cmdSecret(ref const Fields f, ref ByteSink out_)
{
    if (f.count != 2)
        return false;
    Secret s;
    if (!parseSecret(f[1], s))
        return false;
    encodeHex(s.key, out_);
    return true;
}

private bool cmdSign(ref const Fields f, ref ByteSink out_)
{
    if (f.count != 5)
        return false;
    Secret[] secrets;
    long ts;
    ubyte[] payload;
    if (!parseSecrets(f[1], secrets) || !isId(f[2]) || !parseInt(f[3], ts)
        || !decodeHexArg(f[4], payload))
        return false;
    signHeader(secrets, f[2], f[3], payload, out_);
    return true;
}

private bool cmdVerify(ref const Fields f, ref ByteSink out_)
{
    if (f.count != 7)
        return false;
    Secret[] secrets;
    long now;
    ubyte[] header, payload;
    if (!parseSecrets(f[1], secrets) || !isId(f[2]) || !isReceivedTimestamp(f[3])
        || !parseInt(f[4], now) || !decodeHexArg(f[5], header) || !decodeHexArg(f[6], payload))
        return false;
    immutable r = verify(secrets, f[2], f[3], header, payload, now);
    if (r.ok)
    {
        out_.put("ok ");
        out_.putInt(r.secretIndex);
        out_.putChar(' ');
        out_.putInt(r.tokenIndex);
    }
    else
    {
        out_.put("fail ");
        out_.put(failureName(r.failure));
    }
    return true;
}

private bool cmdSimulate(ref LineReader reader, ref ByteSink out_)
{
    Simulation sim;
    if (!parseSimulateBlock(reader, sim))
        return false;
    sim.createDeliveries();
    sim.run();
    sim.render(out_);
    return true;
}

/**
 * Executes every command in `input`, appending each result line to `out_`.
 * Malformed lines produce `error`; this function never throws on bad input.
 */
void processInput(const(ubyte)[] input, ref ByteSink out_)
{
    auto reader = LineReader(input);
    while (!reader.empty)
    {
        auto line = reader.next();
        if (isBlank(line))
            continue;
        immutable mark = out_.length;
        const f = splitFields(line);
        bool ok = false;
        if (f.count > 0 && !f.anyEmpty)
        {
            auto name = f[0];
            if (equals(name, "sha256")) ok = cmdSha256(f, out_);
            else if (equals(name, "hmac")) ok = cmdHmac(f, out_);
            else if (equals(name, "b64enc")) ok = cmdEncode(f, out_, false);
            else if (equals(name, "b64urlenc")) ok = cmdEncode(f, out_, true);
            else if (equals(name, "b64dec")) ok = cmdB64Dec(f, out_);
            else if (equals(name, "secret")) ok = cmdSecret(f, out_);
            else if (equals(name, "sign")) ok = cmdSign(f, out_);
            else if (equals(name, "verify")) ok = cmdVerify(f, out_);
            else if (equals(name, "simulate") && f.count == 1) ok = cmdSimulate(reader, out_);
        }
        if (!ok)
        {
            out_.truncate(mark);
            out_.put("error");
        }
        // A simulate block already ends its last line with '\n'.
        if (out_.length == mark || out_.data[out_.length - 1] != '\n')
            out_.putChar('\n');
    }
}

/// Convenience wrapper: runs `input` and returns the output text.
string processString(string input) @trusted
{
    ByteSink sink;
    processInput(cast(const(ubyte)[]) input, sink);
    return cast(string) sink.data.idup;
}
