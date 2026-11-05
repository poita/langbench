/// Unit tests for secrets, signing and verification.
module tests.signing;

import webhooks.hex;
import webhooks.hmac;
import webhooks.secret;
import webhooks.signature;

private const(ubyte)[] bytes(string s) @trusted pure nothrow
{
    return cast(const(ubyte)[]) s;
}

private enum testSecret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
private enum testId = "msg_p5jXN8AQM9LWM0D4loKWxJek";
private enum testBody = `{"test": 2432232314}`;
private enum testSig = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=";

private HmacKey[] keysOf(string list) @safe
{
    HmacKey[] k;
    assert(parseSecretList(bytes(list), k));
    return k;
}

unittest // secrets
{
    ubyte[] a, b;
    assert(decodeSecret(bytes(testSecret), a));
    assert(decodeSecret(bytes("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"), b));
    assert(a == b && a.length == 24);
    assert(toHex(a) == "31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0");
    assert(decodeSecret(bytes("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr"), b) && b.length == 25);
    assert(!decodeSecret(bytes("whsec_"), b)); // decodes to nothing
    assert(!decodeSecret(bytes(""), b));
    assert(!decodeSecret(bytes("whsec_!!!!"), b));
    // only one prefix is removed; the second is decoded as Base64 text
    ubyte[] c;
    assert(decodeSecret(bytes("whsec_whsec_AAAA"), c) && c.length == 7);
}

unittest // secret field grammar
{
    ubyte[] k;
    assert(parseSecretField(bytes(testSecret), k));
    assert(!parseSecretField(bytes("has space"), k));
    assert(!parseSecretField(bytes("a,b"), k));
    assert(!parseSecretField(bytes(""), k));
    HmacKey[] keys;
    assert(parseSecretList(bytes("AAAA,BBBB"), keys) && keys.length == 2);
    assert(!parseSecretList(bytes("AAAA,,BBBB"), keys));
    assert(!parseSecretList(bytes("AAAA,"), keys));
    string seventeen = "AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA";
    assert(!parseSecretList(bytes(seventeen), keys));
    assert(parseSecretList(bytes(seventeen[0 .. $ - 5]), keys) && keys.length == 16);
}

unittest // canonical integers
{
    long v;
    assert(parseCanonicalInt(bytes("0"), v) && v == 0);
    assert(parseCanonicalInt(bytes("-5"), v) && v == -5);
    assert(parseCanonicalInt(bytes("1000000000000000"), v) && v == 1_000_000_000_000_000);
    assert(!parseCanonicalInt(bytes("1000000000000001"), v));
    foreach (bad; ["", "-", "-0", "+5", "007", "1.0", "1e3", " 1", "1 ", "--1", "99999999999999999999"])
        assert(!parseCanonicalInt(bytes(bad), v), bad);
}

unittest // the published signing test vector
{
    auto keys = keysOf(testSecret);
    assert(signatureHeader(keys, bytes(testId), bytes("1614265330"), bytes(testBody)) == testSig);
}

unittest // rotation: one signature per secret, in order
{
    auto keys = keysOf(testSecret ~ ",AAAA");
    auto h = signatureHeader(keys, bytes(testId), bytes("1614265330"), bytes(testBody));
    assert(h.length == 2 * 47 + 1 && h[0 .. 47] == testSig && h[47] == ' ');
}

unittest // verify: success and each failure reason
{
    auto keys = keysOf(testSecret);
    auto id = bytes(testId);
    auto ts = bytes("1614265330");
    auto body_ = bytes(testBody);

    auto r = verify(keys, id, ts, bytes(testSig), body_, 1614265400);
    assert(r.ok && r.secretIndex == 0 && r.tokenIndex == 0);

    assert(verify(keys, id, ts, bytes(testSig), body_, 1614265630).ok); // exactly 300 old
    assert(verify(keys, id, ts, bytes(testSig), body_, 1614265030).ok); // exactly 300 new
    assert(verify(keys, id, ts, bytes(testSig), body_, 1614265631).status == VerifyStatus.timestampTooOld);
    assert(verify(keys, id, ts, bytes(testSig), body_, 1614265029).status == VerifyStatus.timestampTooNew);
    assert(verify(keys, id, ts, bytes(""), body_, 1614265400).status == VerifyStatus.missingSignature);
    assert(verify(keys, id, ts, bytes("  "), body_, 1614265400).status == VerifyStatus.missingSignature);
    assert(verify(keys, id, bytes("0123"), bytes(testSig), body_, 1).status == VerifyStatus.invalidTimestamp);
    assert(verify(keys, id, ts, bytes(testSig), bytes("{}"), 1614265400).status == VerifyStatus.noMatch);
    // missing-signature is decided before the timestamp is looked at
    assert(verify(keys, id, bytes("x"), bytes(""), body_, 1).status == VerifyStatus.missingSignature);
}

unittest // verify: token handling
{
    auto keys = keysOf(testSecret);
    auto id = bytes(testId);
    auto ts = bytes("1614265330");
    auto body_ = bytes(testBody);

    auto r = verify(keys, id, ts, bytes("garbage v1,bad " ~ testSig), body_, 1614265330);
    assert(r.ok && r.tokenIndex == 2);
    // empty tokens still count toward the index
    r = verify(keys, id, ts, bytes("  " ~ testSig), body_, 1614265330);
    assert(r.ok && r.tokenIndex == 2);
    // wrong version, missing comma
    assert(!verify(keys, id, ts, bytes("v2," ~ testSig[3 .. $]), body_, 1614265330).ok);
    assert(!verify(keys, id, ts, bytes(testSig[0 .. 2] ~ testSig[3 .. $]), body_, 1614265330).ok);
    // URL-safe, unpadded form of the same MAC is accepted
    auto unpadded = "v1,g0hM9SsE-OTPJTGt_tmIKtSyZlE3uFJELVlNIOLJ1OE";
    assert(verify(keys, id, ts, bytes(unpadded), body_, 1614265330).ok);
}

unittest // verify: key rotation picks the first matching secret, then token
{
    auto both = keysOf("AAAA," ~ testSecret);
    auto id = bytes(testId);
    auto ts = bytes("1614265330");
    auto r = verify(both, id, ts, bytes(testSig), bytes(testBody), 1614265330);
    assert(r.ok && r.secretIndex == 1 && r.tokenIndex == 0);
    r = verify(both, id, ts, bytes(testSig ~ " " ~ testSig), bytes(testBody), 1614265330);
    assert(r.ok && r.tokenIndex == 0);
}

unittest // signing then verifying round-trips for arbitrary bodies
{
    auto keys = keysOf("c2VjcmV0,b3RoZXI");
    auto body_ = new ubyte[1000];
    foreach (i, ref b; body_)
        b = cast(ubyte) i;
    auto header = signatureHeader(keys, bytes("id.with.dots"), bytes("-42"), body_);
    auto r = verify(keys, bytes("id.with.dots"), bytes("-42"), bytes(header), body_, -40);
    assert(r.ok && r.secretIndex == 0 && r.tokenIndex == 0);
    auto only2 = keysOf("b3RoZXI");
    r = verify(only2, bytes("id.with.dots"), bytes("-42"), bytes(header), body_, -40);
    assert(r.ok && r.tokenIndex == 1);
}
