/// Unit tests for signing and verification.
module tests.signature_test;

import webhooks;

private const(ubyte)[] bytes(string s)
{
    return asBytes(s);
}

private immutable secretText = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
private immutable msgId = "msg_p5jXN8AQM9LWM0D4loKWxJek";
private immutable payload = `{"test": 2432232314}`;
private immutable goodSig = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=";

private HmacKey[] keysOf(string list)
{
    HmacKey[] keys;
    assert(parseSecrets(bytes(list), keys));
    return keys;
}

unittest
{
    auto keys = keysOf(secretText);
    assert(sign(keys, bytes(msgId), bytes("1614265330"), bytes(payload)) == goodSig);
}

unittest
{
    // Key rotation: one signature per secret, in order, separated by single spaces.
    auto keys = keysOf(secretText ~ ",whsec_c2VjcmV0");
    auto header = sign(keys, bytes(msgId), bytes("1614265330"), bytes(payload));
    assert(header.length == 2 * 47 + 1);
    assert(header[0 .. 47] == goodSig && header[47] == ' ');
}

unittest
{
    auto keys = keysOf(secretText);
    auto v = verify(keys, bytes(msgId), bytes("1614265330"), 1614265400, bytes(goodSig), bytes(payload));
    assert(v.status == VerifyStatus.ok && v.secretIndex == 0 && v.tokenIndex == 0);
}

unittest
{
    auto keys = keysOf(secretText);
    auto id = bytes(msgId);
    auto ts = bytes("1614265330");
    auto body_ = bytes(payload);

    // tolerance is inclusive
    assert(verify(keys, id, ts, 1614265330 + 300, bytes(goodSig), body_).status == VerifyStatus.ok);
    assert(verify(keys, id, ts, 1614265330 - 300, bytes(goodSig), body_).status == VerifyStatus.ok);
    assert(verify(keys, id, ts, 1614265330 + 301, bytes(goodSig), body_).status == VerifyStatus.timestampTooOld);
    assert(verify(keys, id, ts, 1614265330 - 301, bytes(goodSig), body_).status == VerifyStatus.timestampTooNew);
}

unittest
{
    auto keys = keysOf(secretText);
    auto id = bytes(msgId);
    auto body_ = bytes(payload);
    // Order of checks: missing signature wins over a bad timestamp; a bad timestamp wins over staleness.
    assert(verify(keys, id, bytes("junk"), 0, bytes(""), body_).status == VerifyStatus.missingSignature);
    assert(verify(keys, id, bytes("junk"), 0, bytes("  "), body_).status == VerifyStatus.missingSignature);
    assert(verify(keys, id, bytes("junk"), 0, bytes(goodSig), body_).status == VerifyStatus.invalidTimestamp);
    foreach (bad; ["007", "+5", "-0", "1000000000000001", "1.5", " 1"])
        assert(verify(keys, id, bytes(bad), 0, bytes(goodSig), body_).status == VerifyStatus.invalidTimestamp, bad);
    // Differences of two extreme timestamps do not overflow.
    assert(verify(keys, id, bytes("-1000000000000000"), 1_000_000_000_000_000, bytes(goodSig), body_).status
            == VerifyStatus.timestampTooOld);
}

unittest
{
    auto keys = keysOf(secretText);
    auto id = bytes(msgId);
    auto ts = bytes("1614265330");
    long now = 1614265400;
    // tampered body, id, timestamp
    assert(verify(keys, id, ts, now, bytes(goodSig), bytes("{}")).status == VerifyStatus.noMatch);
    assert(verify(keys, bytes("other"), ts, now, bytes(goodSig), bytes(payload)).status == VerifyStatus.noMatch);
    assert(verify(keys, id, bytes("1614265331"), now, bytes(goodSig), bytes(payload)).status == VerifyStatus.noMatch);
}

unittest
{
    auto keys = keysOf(secretText);
    auto id = bytes(msgId);
    auto ts = bytes("1614265330");
    long now = 1614265400;
    auto body_ = bytes(payload);
    // Bad tokens are skipped; the token index counts empty tokens too.
    auto v = verify(keys, id, ts, now, bytes("garbage v1," ~ goodSig[3 .. $]), body_);
    assert(v.status == VerifyStatus.ok && v.tokenIndex == 1);
    v = verify(keys, id, ts, now, bytes("  " ~ goodSig), body_);
    assert(v.status == VerifyStatus.ok && v.tokenIndex == 2);
    // wrong version, no comma, wrong length, mixed alphabet
    foreach (bad; ["v2," ~ goodSig[3 .. $], goodSig[3 .. $], "v1,AAAA", "v1,", "v1," ~ goodSig[3 .. $] ~ "A",
            "V1," ~ goodSig[3 .. $], "v1;" ~ goodSig[3 .. $]])
        assert(verify(keys, id, ts, now, bytes(bad), body_).status == VerifyStatus.noMatch, bad);
    // Unpadded Base64 of the MAC is accepted.
    assert(verify(keys, id, ts, now, bytes(goodSig[0 .. $ - 1]), body_).status == VerifyStatus.ok);
}

unittest
{
    // Rotation: the result names the first matching (secret, token) pair, secret-major.
    auto keys = keysOf("whsec_c2VjcmV0," ~ secretText);
    auto id = bytes(msgId);
    auto ts = bytes("1614265330");
    auto body_ = bytes(payload);
    auto sigs = sign(keys, id, ts, body_);
    auto v = verify(keys, id, ts, 1614265330, bytes(sigs), body_);
    assert(v.status == VerifyStatus.ok && v.secretIndex == 0 && v.tokenIndex == 0);
    // Only the second signature present: secret 1 matches token 0.
    v = verify(keys, id, ts, 1614265330, bytes(sigs[47 + 1 .. $]), body_);
    assert(v.status == VerifyStatus.ok && v.secretIndex == 1 && v.tokenIndex == 0);
    // Reversed header: secret 0 is preferred over token order.
    v = verify(keys, id, ts, 1614265330, bytes(sigs[48 .. $] ~ " " ~ sigs[0 .. 47]), body_);
    assert(v.status == VerifyStatus.ok && v.secretIndex == 0 && v.tokenIndex == 1);
}

unittest
{
    assert(reason(VerifyStatus.noMatch) == "no-match");
    assert(reason(VerifyStatus.timestampTooOld) == "timestamp-too-old");
    assert(reason(VerifyStatus.timestampTooNew) == "timestamp-too-new");
    assert(reason(VerifyStatus.invalidTimestamp) == "invalid-timestamp");
    assert(reason(VerifyStatus.missingSignature) == "missing-signature");
}
