/**
 * The line-oriented command protocol: reads commands from a byte buffer and
 * writes one result per command to an output sink.
 *
 * See the project README for the command list. Every malformed command
 * produces the single word `error`; processing never fails.
 */
module webhooks.protocol;

import webhooks.base64;
import webhooks.blockparser;
import webhooks.fields;
import webhooks.hex;
import webhooks.hmac;
import webhooks.secret;
import webhooks.sha256;
import webhooks.signature;
import webhooks.simulator;

private bool eq(scope const(ubyte)[] bytes, string text) pure nothrow @trusted @nogc
{
    return bytes == cast(const(ubyte)[]) text;
}

private void putLine(Sink)(ref Sink sink, scope const(char)[] text)
{
    sink.put(text);
    sink.put("\n");
}

/**
 * Executes one command line (not `simulate`, which spans several lines) and
 * writes its single output line to `sink`.
 *
 * Params:
 *   fields = the line already split into fields
 *   sink = an output range accepting `const(char)[]`
 */
void executeCommand(Sink)(const(ubyte)[][] fields, ref Sink sink)
{
    auto name = fields[0];

    string result = "error";
    if (eq(name, "sha256") && fields.length == 2)
        result = cmdSha256(fields);
    else if (eq(name, "hmac") && fields.length == 3)
        result = cmdHmac(fields);
    else if (eq(name, "b64enc") && fields.length == 2)
        result = cmdB64(fields, false);
    else if (eq(name, "b64urlenc") && fields.length == 2)
        result = cmdB64(fields, true);
    else if (eq(name, "b64dec") && fields.length == 2)
        result = cmdB64dec(fields);
    else if (eq(name, "secret") && fields.length == 2)
        result = cmdSecret(fields);
    else if (eq(name, "sign") && fields.length == 5)
        result = cmdSign(fields);
    else if (eq(name, "verify") && fields.length == 7)
        result = cmdVerify(fields);
    putLine(sink, result);
}

private string cmdSha256(const(ubyte)[][] f)
{
    ubyte[] data;
    if (!parseHexField(f[1], data))
        return "error";
    return toHex(sha256(data));
}

private string cmdHmac(const(ubyte)[][] f)
{
    ubyte[] key, message;
    if (!parseHexField(f[1], key) || !parseHexField(f[2], message))
        return "error";
    return toHex(hmacSha256(key, message));
}

private string cmdB64(const(ubyte)[][] f, bool urlSafe)
{
    ubyte[] data;
    if (!parseHexField(f[1], data))
        return "error";
    immutable text = urlSafe ? encodeBase64Url(data) : encodeBase64(data);
    return text.length == 0 ? "-" : text;
}

private string cmdB64dec(const(ubyte)[][] f)
{
    ubyte[] text, decoded;
    if (!parseHexField(f[1], text) || !decodeBase64(text, decoded))
        return "error";
    return toHexField(decoded);
}

private string cmdSecret(const(ubyte)[][] f)
{
    Secret s;
    if (!parseSecretField(f[1], s))
        return "error";
    return toHexField(s.key);
}

private string cmdSign(const(ubyte)[][] f)
{
    Secret[] secrets;
    long ts;
    ubyte[] payload;
    if (!parseSecretsField(f[1], secrets) || !isId(f[2]) || !parseInt(f[3], ts)
            || !parseHexField(f[4], payload))
        return "error";
    return signatureHeader(secrets, f[2], f[3], payload);
}

private string cmdVerify(const(ubyte)[][] f)
{
    Secret[] secrets;
    long now;
    ubyte[] header, payload;
    if (!parseSecretsField(f[1], secrets) || !isId(f[2]) || !isGraphicField(f[3], 64)
            || !parseInt(f[4], now) || !parseHexField(f[5], header) || !parseHexField(f[6], payload))
        return "error";
    immutable r = verify(secrets, f[2], f[3], header, payload, now);
    if (!r.ok)
        return "fail " ~ failureName(r.failure);
    return "ok " ~ decimal(r.secretIndex) ~ " " ~ decimal(r.tokenIndex);
}

private string decimal(size_t n) pure nothrow @safe
{
    char[20] buf = void;
    size_t pos = buf.length;
    do
    {
        buf[--pos] = cast(char)('0' + n % 10);
        n /= 10;
    }
    while (n != 0);
    return buf[pos .. $].idup;
}

/**
 * Processes a whole input: executes every command (and `simulate` block) in
 * `input`, writing each result to `sink`.
 *
 * Params:
 *   input = the complete input text as bytes
 *   sink = an output range accepting `const(char)[]` chunks
 */
void processInput(Sink)(const(ubyte)[] input, ref Sink sink)
{
    auto reader = LineReader(input);
    const(ubyte)[] line;
    while (reader.next(line))
    {
        const(ubyte)[][] fields;
        if (!splitFields(line, 8, fields))
        {
            putLine(sink, "error");
            continue;
        }
        if (eq(fields[0], "simulate") && fields.length == 1)
        {
            Scenario scenario;
            if (readBlock(reader, scenario))
            {
                auto result = simulate(scenario);
                writeReport(sink, scenario, result);
            }
            else
                putLine(sink, "error");
            continue;
        }
        executeCommand(fields, sink);
    }
}

/// Convenience wrapper around `processInput` returning the output as a string.
string processInputToString(scope const(char)[] input) @trusted
{
    import std.array : appender;

    auto sink = appender!string();
    processInput(cast(const(ubyte)[]) input, sink);
    return sink[];
}

version (unittest)
{
    private string run(string input) @safe
    {
        return processInputToString(input);
    }
}

@safe unittest
{
    assert(run("sha256 -\nsha256 616263\nhmac - -\n") ~ "" ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n"
            ~ "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n"
            ~ "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad\n");
    assert(run("b64enc 666f6f\nb64urlenc fbff\nb64dec 5a6d3976\nb64dec -\nb64enc -\n")
            == "Zm9v\n-_8\n666f6f\n-\n-\n");
}

@safe unittest
{
    // Errors: bad hex, odd length, unknown command, wrong arity, empty field, tab.
    assert(run("sha256 ABCD\nsha256 abc\nfrobnicate 1\nsha256\nsha256 a b\nsha256  \nsha256\t-\n")
            == "error\nerror\nerror\nerror\nerror\nerror\nerror\n");
    // Blank and space-only lines are skipped; a missing final newline is fine.
    assert(run("\n   \nsha256 -") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n");
    assert(run("b64dec 5a6d3 \n") == "error\n");
    assert(run("b64dec 20\nb64dec 5a6d20\nb64dec 5a67\n") == "error\nerror\n66\n");
}

@safe unittest
{
    enum secret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
    enum id = "msg_p5jXN8AQM9LWM0D4loKWxJek";
    enum payload = "7b2274657374223a20323433323233323331347d";
    enum header = "76312c6730684d395373452b4f54504a5447742f746d494b7453795a6c453375464a454c566c4e494f4c4a314f453d";
    assert(run("secret " ~ secret ~ "\nsecret whsec_\nsecret a,b\n")
            == "31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0\nerror\nerror\n");
    assert(run("sign " ~ secret ~ " " ~ id ~ " 1614265330 " ~ payload ~ "\n")
            == "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=\n");
    enum v = "verify " ~ secret ~ " " ~ id ~ " 1614265330 ";
    assert(run(v ~ "1614265400 " ~ header ~ " " ~ payload ~ "\n"
            ~ v ~ "1614265631 " ~ header ~ " " ~ payload ~ "\n"
            ~ v ~ "1614265400 " ~ header ~ " 7b7d\n"
            ~ v ~ "1614265400 - " ~ payload ~ "\n"
            ~ "verify " ~ secret ~ " " ~ id ~ " 0001 1614265400 " ~ header ~ " " ~ payload ~ "\n"
            ~ "sign " ~ secret ~ " " ~ id ~ " 0001 " ~ payload ~ "\n")
            == "ok 0 0\nfail timestamp-too-old\nfail no-match\nfail missing-signature\n"
            ~ "fail invalid-timestamp\nerror\n");
}

@safe unittest
{
    // A malformed block yields one `error` and the next command still runs.
    assert(run("simulate\nendpoint a\nevent x\nend\nsha256 -\n")
            == "error\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n");
    // `simulate` with extra fields does not open a block.
    assert(run("simulate now\nend\nevent a\n") == "error\nerror\nerror\n");
    // Unterminated block.
    assert(run("simulate\nendpoint a c2VjcmV0 * 200\n") == "error\n");
    // Empty block (valid endpoints, no events).
    assert(run("simulate\nendpoint a c2VjcmV0 * 200\nend\n") == "sim 0 0\n");
}
