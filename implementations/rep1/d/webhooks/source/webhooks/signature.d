/**
 * The Standard Webhooks signature scheme: signing a message with one or more
 * secrets and verifying a received `webhook-signature` header.
 */
module webhooks.signature;

import webhooks.base64;
import webhooks.hmac;
import webhooks.secret;

/// Tolerance, in seconds, between the message timestamp and the verifier's clock.
enum long timestampTolerance = 300;
/// Largest absolute timestamp accepted as a canonical integer.
enum long maxTimestamp = 1_000_000_000_000_000;

/**
 * Parses a canonical decimal integer: `0`, or an optional `-` followed by a
 * non-zero digit and more digits, with absolute value at most 10^15.
 *
 * Returns: `true` and fills `value` if `text` is canonical.
 */
bool parseCanonicalInt(scope const(ubyte)[] text, out long value) pure nothrow @safe @nogc
{
    if (text.length == 0)
        return false;
    if (text.length == 1 && text[0] == '0')
    {
        value = 0;
        return true;
    }
    immutable negative = text[0] == '-';
    auto digits = negative ? text[1 .. $] : text;
    // 10^15 has 16 digits; refuse longer input before it can overflow.
    if (digits.length == 0 || digits.length > 16 || digits[0] < '1' || digits[0] > '9')
        return false;
    long v = 0;
    foreach (c; digits)
    {
        if (c < '0' || c > '9')
            return false;
        v = v * 10 + (c - '0');
    }
    if (v > maxTimestamp)
        return false;
    value = negative ? -v : v;
    return true;
}

/// ditto
bool parseCanonicalInt(scope const(char)[] text, out long value) pure nothrow @trusted @nogc
{
    return parseCanonicalInt(cast(const(ubyte)[]) text, value);
}

/// Feeds the signed content `id "." timestamp "." body` into `mac`.
private void putSignedContent(ref Hmac mac, scope const(ubyte)[] id, scope const(ubyte)[] timestamp,
    scope const(ubyte)[] body_) pure nothrow @safe @nogc
{
    mac.put(id);
    mac.put(cast(const(ubyte)[]) ".");
    mac.put(timestamp);
    mac.put(cast(const(ubyte)[]) ".");
    mac.put(body_);
}

/// The 32-byte HMAC of the signed content under `secret`.
ubyte[32] computeMac(ref const Secret secret, scope const(ubyte)[] id,
    scope const(ubyte)[] timestamp, scope const(ubyte)[] body_) pure nothrow @safe @nogc
{
    Hmac mac = secret.keyed;
    putSignedContent(mac, id, timestamp, body_);
    return mac.finish();
}

/// The `v1,<base64>` signature of one message under one secret.
string sign(ref const Secret secret, scope const(ubyte)[] id,
    scope const(ubyte)[] timestamp, scope const(ubyte)[] body_) pure nothrow @safe
{
    immutable mac = computeMac(secret, id, timestamp, body_);
    return "v1," ~ encodeBase64(mac[]);
}

/**
 * The `webhook-signature` header value for a message: one `v1,<base64>`
 * signature per secret, in order, joined by single spaces.
 */
string signatureHeader(scope const(Secret)[] secrets, scope const(ubyte)[] id,
    scope const(ubyte)[] timestamp, scope const(ubyte)[] body_) pure nothrow @safe
{
    string header;
    foreach (i, ref secret; secrets)
    {
        if (i > 0)
            header ~= ' ';
        header ~= sign(secret, id, timestamp, body_);
    }
    return header;
}

/// Why a verification failed.
enum VerifyFailure
{
    none,
    missingSignature,
    invalidTimestamp,
    timestampTooOld,
    timestampTooNew,
    noMatch,
}

/// The protocol name of a failure reason, e.g. `timestamp-too-old`.
string failureName(VerifyFailure f) pure nothrow @safe @nogc
{
    final switch (f)
    {
    case VerifyFailure.none:
        return "none";
    case VerifyFailure.missingSignature:
        return "missing-signature";
    case VerifyFailure.invalidTimestamp:
        return "invalid-timestamp";
    case VerifyFailure.timestampTooOld:
        return "timestamp-too-old";
    case VerifyFailure.timestampTooNew:
        return "timestamp-too-new";
    case VerifyFailure.noMatch:
        return "no-match";
    }
}

/// Outcome of `verify`.
struct VerifyResult
{
    /// `true` if some signature matched.
    bool ok;
    /// On failure, the reason.
    VerifyFailure failure;
    /// On success, the 0-based index of the matching secret.
    size_t secretIndex;
    /// On success, the 0-based index of the matching header token (empty
    /// tokens between spaces count).
    size_t tokenIndex;
}

/**
 * Verifies a received message.
 *
 * The checks run in a fixed order and stop at the first that decides:
 * the header must contain a non-empty token; the timestamp must be a canonical
 * integer; it must lie within `timestampTolerance` seconds of `now`; and some
 * `v1` token must match the HMAC of some secret. One MAC is computed per
 * secret, and every header token is Base64-decoded at most once.
 *
 * Params:
 *   secrets = the active secrets, in order
 *   id = the received `webhook-id`
 *   timestamp = the received `webhook-timestamp` text
 *   header = the received `webhook-signature` value
 *   body_ = the raw request body
 *   now = the verifier's clock, Unix seconds
 */
VerifyResult verify(scope const(Secret)[] secrets, scope const(ubyte)[] id,
    scope const(ubyte)[] timestamp, scope const(ubyte)[] header, scope const(ubyte)[] body_,
    long now) pure nothrow @safe
{
    VerifyResult fail(VerifyFailure why)
    {
        VerifyResult r;
        r.failure = why;
        return r;
    }

    // 1. Split the header on single spaces.
    const(ubyte)[][] tokens;
    bool anyNonEmpty = false;
    size_t start = 0;
    foreach (i; 0 .. header.length + 1)
    {
        if (i == header.length || header[i] == ' ')
        {
            tokens ~= header[start .. i];
            if (i > start)
                anyNonEmpty = true;
            start = i + 1;
        }
    }
    if (!anyNonEmpty)
        return fail(VerifyFailure.missingSignature);

    // 2. Timestamp must be canonical.
    long ts;
    if (!parseCanonicalInt(timestamp, ts))
        return fail(VerifyFailure.invalidTimestamp);

    // 3. Tolerance (inclusive).
    if (now - ts > timestampTolerance)
        return fail(VerifyFailure.timestampTooOld);
    if (ts - now > timestampTolerance)
        return fail(VerifyFailure.timestampTooNew);

    // 4. Decode each `v1,<value>` token once.
    struct Candidate
    {
        bool usable;
        ubyte[] bytes;
    }

    auto candidates = new Candidate[tokens.length];
    foreach (j, token; tokens)
    {
        size_t comma = 0;
        while (comma < token.length && token[comma] != ',')
            ++comma;
        if (comma == token.length || token[0 .. comma] != cast(const(ubyte)[]) "v1")
            continue;
        candidates[j].usable = decodeBase64(token[comma + 1 .. $], candidates[j].bytes);
    }

    foreach (i, ref secret; secrets)
    {
        immutable mac = computeMac(secret, id, timestamp, body_);
        foreach (j, ref c; candidates)
        {
            if (c.usable && constantTimeEqual(c.bytes, mac[]))
            {
                VerifyResult r;
                r.ok = true;
                r.secretIndex = i;
                r.tokenIndex = j;
                return r;
            }
        }
    }
    return fail(VerifyFailure.noMatch);
}

/// Compares two byte strings without exiting early on the first difference
/// (when the lengths are equal).
bool constantTimeEqual(scope const(ubyte)[] a, scope const(ubyte)[] b) pure nothrow @safe @nogc
{
    if (a.length != b.length)
        return false;
    ubyte diff = 0;
    foreach (i; 0 .. a.length)
        diff |= a[i] ^ b[i];
    return diff == 0;
}

version (unittest)
{
    private Secret testSecret(string text) @safe
    {
        Secret s;
        assert(Secret.parse(text, s));
        return s;
    }

    private immutable testId = cast(immutable(ubyte)[]) "msg_p5jXN8AQM9LWM0D4loKWxJek";
    private immutable testTs = cast(immutable(ubyte)[]) "1614265330";
    private immutable testBody = cast(immutable(ubyte)[]) `{"test": 2432232314}`;
    private immutable testHeader = cast(immutable(ubyte)[]) "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=";
}

/// The published Standard Webhooks test vector.
@safe unittest
{
    auto s = testSecret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw");
    assert(sign(s, testId, testTs, testBody) == "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=");

    auto r = verify([s], testId, testTs, testHeader, testBody, 1614265400);
    assert(r.ok && r.secretIndex == 0 && r.tokenIndex == 0);
}

@safe unittest
{
    auto s = testSecret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw");
    // Tolerance is inclusive.
    assert(verify([s], testId, testTs, testHeader, testBody, 1614265630).ok);
    assert(verify([s], testId, testTs, testHeader, testBody, 1614265631).failure
            == VerifyFailure.timestampTooOld);
    assert(verify([s], testId, testTs, testHeader, testBody, 1614265030).ok);
    assert(verify([s], testId, testTs, testHeader, testBody, 1614265029).failure
            == VerifyFailure.timestampTooNew);
    // Body changed / empty header / bad timestamp.
    assert(verify([s], testId, testTs, testHeader, cast(const(ubyte)[]) "{}", 1614265400).failure
            == VerifyFailure.noMatch);
    assert(verify([s], testId, testTs, [], testBody, 1614265400).failure
            == VerifyFailure.missingSignature);
    assert(verify([s], testId, testTs, cast(const(ubyte)[]) "  ", testBody, 1614265400).failure
            == VerifyFailure.missingSignature);
    assert(verify([s], testId, cast(const(ubyte)[]) "01614265330", testHeader, testBody, 1614265400).failure
            == VerifyFailure.invalidTimestamp);
}

@safe unittest
{
    auto s0 = testSecret("c2VjcmV0");
    auto s1 = testSecret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw");
    // Garbage and empty tokens are skipped but counted; secret order wins over token order.
    auto header = cast(const(ubyte)[]) ("garbage  v1,!!! v2,AAAA " ~ cast(string) testHeader);
    auto r = verify([s0, s1], testId, testTs, header, testBody, 1614265330);
    assert(r.ok && r.secretIndex == 1 && r.tokenIndex == 4);
}

@safe unittest
{
    long v;
    assert(parseCanonicalInt("0", v) && v == 0);
    assert(parseCanonicalInt("-5", v) && v == -5);
    assert(parseCanonicalInt("1000000000000000", v) && v == maxTimestamp);
    assert(parseCanonicalInt("-1000000000000000", v) && v == -maxTimestamp);
    foreach (bad; ["", "-", "-0", "+5", "007", "1.0", "1e3", "1000000000000001",
            "99999999999999999999", " 1", "1 "])
        assert(!parseCanonicalInt(bad, v), bad);
}
