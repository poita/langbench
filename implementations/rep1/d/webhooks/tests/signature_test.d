module signature_test;

import webhooks.buffer;
import webhooks.hex : toHex;
import webhooks.signature;

private const(ubyte)[] b(string s) { return cast(const(ubyte)[]) s; }

private enum secretText = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
private enum msgId = "msg_p5jXN8AQM9LWM0D4loKWxJek";
private enum body_ = `{"test": 2432232314}`;
private enum header = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=";

private Secret[] secrets(string s)
{
    Secret[] r;
    assert(parseSecrets(b(s), r));
    return r;
}

private string sign(Secret[] s, string id, string ts, string body)
{
    ByteSink sink;
    signHeader(s, b(id), b(ts), b(body), sink);
    return cast(string) sink.data.idup;
}

@("secret: prefix handling")
unittest
{
    Secret a, c;
    assert(parseSecret(b(secretText), a));
    assert(parseSecret(b("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"), c));
    assert(a.key == c.key && a.key.length == 24);
    assert(toHex(a.key) == "31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0");
    Secret d;
    assert(parseSecret(b("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr"), d) && d.key.length == 25);
    // Only the first prefix is stripped.
    Secret e, f;
    assert(parseSecret(b("whsec_whsec_"), e) && parseSecret(b("whsec_"), f) == false);
    assert(e.key.length == 4); // "whsec_" itself is Base64-decoded
}

@("secret: invalid secrets")
unittest
{
    Secret s;
    foreach (bad; ["", "whsec_", "A", "a,b", "ab cd", "====", "+-+-"])
        assert(!parseSecret(b(bad), s), bad);
    Secret[] many;
    assert(!parseSecrets(b("QQ,,QQ"), many));
    assert(!parseSecrets(b("QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ"), many));
    assert(parseSecrets(b("QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ,QQ"), many) && many.length == 16);
}

@("sign: published Standard Webhooks vector")
unittest
{
    assert(sign(secrets(secretText), msgId, "1614265330", body_) == header);
}

@("sign: rotation joins signatures with spaces in secret order")
unittest
{
    auto both = sign(secrets(secretText ~ ",c2VjcmV0"), msgId, "1614265330", body_);
    assert(both[0 .. header.length] == header);
    assert(both[header.length] == ' ' && both.length == 2 * header.length + 1);
}

@("verify: success and indices")
unittest
{
    auto s = secrets("c2VjcmV0," ~ secretText);
    auto r = verify(s, b(msgId), b("1614265330"), b("garbage " ~ header), b(body_), 1614265400);
    assert(r.ok && r.secretIndex == 1 && r.tokenIndex == 1);
}

@("verify: tolerance is inclusive")
unittest
{
    auto s = secrets(secretText);
    assert(verify(s, b(msgId), b("1614265330"), b(header), b(body_), 1614265630).ok);
    assert(verify(s, b(msgId), b("1614265330"), b(header), b(body_), 1614265030).ok);
    assert(verify(s, b(msgId), b("1614265330"), b(header), b(body_), 1614265631).failure
        == VerifyFailure.timestampTooOld);
    assert(verify(s, b(msgId), b("1614265330"), b(header), b(body_), 1614265029).failure
        == VerifyFailure.timestampTooNew);
}

@("verify: failure ordering")
unittest
{
    auto s = secrets(secretText);
    // Empty header wins over a bad timestamp.
    assert(verify(s, b(msgId), b("abc"), b(""), b(body_), 0).failure == VerifyFailure.missingSignature);
    assert(verify(s, b(msgId), b("abc"), b("  "), b(body_), 0).failure == VerifyFailure.missingSignature);
    assert(verify(s, b(msgId), b("007"), b(header), b(body_), 7).failure == VerifyFailure.invalidTimestamp);
    assert(verify(s, b(msgId), b("1614265330"), b(header), b("{}"), 1614265330).failure
        == VerifyFailure.noMatch);
}

@("verify: token index counts empty tokens; bad tokens are skipped")
unittest
{
    auto s = secrets(secretText);
    auto r = verify(s, b(msgId), b("1614265330"), b("  v2,xx v1 v1,!! " ~ header),
        b(body_), 1614265330);
    assert(r.ok && r.tokenIndex == 5);
}

@("verify: unpadded and URL-safe signature values are accepted")
unittest
{
    auto s = secrets(secretText);
    // The header's Base64 without its trailing '='.
    assert(verify(s, b(msgId), b("1614265330"), b(header[0 .. $ - 1]), b(body_), 1614265330).ok);
}
