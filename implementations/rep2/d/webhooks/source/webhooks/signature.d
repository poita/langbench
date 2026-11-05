/**
 * The Standard Webhooks signature scheme: signing and verification.
 */
module webhooks.signature;

import webhooks.base64;
import webhooks.hmac;
import webhooks.outbuf;

/// Allowed clock skew, in seconds, in either direction (inclusive).
enum long toleranceSeconds = 300;
/// Largest absolute value of a canonical timestamp.
enum long maxTimestamp = 1_000_000_000_000_000;

/// Why verification succeeded or failed.
enum VerifyStatus : ubyte
{
    ok,
    missingSignature,
    invalidTimestamp,
    timestampTooOld,
    timestampTooNew,
    noMatch,
}

/// The protocol name of a status (`missing-signature`, ...; `ok` for success).
string statusName(VerifyStatus s) @safe pure nothrow @nogc
{
    final switch (s)
    {
    case VerifyStatus.ok:
        return "ok";
    case VerifyStatus.missingSignature:
        return "missing-signature";
    case VerifyStatus.invalidTimestamp:
        return "invalid-timestamp";
    case VerifyStatus.timestampTooOld:
        return "timestamp-too-old";
    case VerifyStatus.timestampTooNew:
        return "timestamp-too-new";
    case VerifyStatus.noMatch:
        return "no-match";
    }
}

/// Outcome of `verify`. On success `secretIndex`/`tokenIndex` locate the match.
struct VerifyResult
{
    VerifyStatus status;
    size_t secretIndex;
    size_t tokenIndex;

    /// True if a signature matched.
    @property bool ok() const @safe pure nothrow @nogc
    {
        return status == VerifyStatus.ok;
    }
}

/**
 * Parses a canonical decimal integer: `0`, or an optional `-` and a digit
 * `1`-`9` followed by digits, with absolute value at most 10^15.
 *
 * Returns: whether `text` is canonical; `value` is set only then.
 */
bool parseCanonicalInt(scope const(ubyte)[] text, out long value) @safe pure nothrow @nogc
{
    if (text.length == 0)
        return false;
    immutable negative = text[0] == '-';
    auto digits = negative ? text[1 .. $] : text;
    if (digits.length == 0 || digits.length > 16)
        return false;
    if (digits[0] == '0')
    {
        if (digits.length != 1 || negative)
            return false;
        value = 0;
        return true;
    }
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

private immutable ubyte[1] dot = ['.'];

/// MAC of `id "." ts "." body`, streamed through `key`.
ubyte[32] signedContentMac(ref const HmacKey key, scope const(ubyte)[] id,
    scope const(ubyte)[] ts, scope const(ubyte)[] body_) @safe pure nothrow @nogc
{
    return key.mac(id, dot[], ts, dot[], body_);
}

/**
 * Appends the `webhook-signature` header value: one `v1,<base64>` per key,
 * in order, joined by single spaces.
 */
void appendSignatureHeader(ref OutBuf output, scope const(HmacKey)[] keys,
    scope const(ubyte)[] id, scope const(ubyte)[] ts, scope const(ubyte)[] body_) @safe pure nothrow
{
    foreach (i, ref key; keys)
    {
        if (i != 0)
            output.putByte(' ');
        output.put("v1,");
        immutable digest = signedContentMac(key, id, ts, body_);
        appendEncoded(output, digest[]);
    }
}

/// The `webhook-signature` header value for the given keys and message.
string signatureHeader(scope const(HmacKey)[] keys, scope const(ubyte)[] id,
    scope const(ubyte)[] ts, scope const(ubyte)[] body_) @trusted pure nothrow
{
    OutBuf o;
    appendSignatureHeader(o, keys, id, ts, body_);
    return cast(string) o.data.idup;
}

private bool constantTimeEqual(scope const(ubyte)[] a, scope const(ubyte)[] b) @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    ubyte diff = 0;
    foreach (i; 0 .. a.length)
        diff |= a[i] ^ b[i];
    return diff == 0;
}

private struct Candidate
{
    size_t token;
    ubyte[32] digest;
}

/**
 * Verifies a received webhook.
 *
 * Steps, in order: header present; timestamp canonical; timestamp within
 * `toleranceSeconds` of `now`; then the first `(secret, header token)` pair
 * whose token is `v1,<base64 of the expected MAC>`.
 *
 * Each header token is decoded once and each secret's MAC is computed once.
 *
 * Params:
 *   keys = active keys, in order
 *   id = received `webhook-id`
 *   ts = received `webhook-timestamp` text
 *   header = received `webhook-signature` value
 *   body_ = request body
 *   now = current Unix time in seconds
 */
VerifyResult verify(scope const(HmacKey)[] keys, scope const(ubyte)[] id, scope const(ubyte)[] ts,
    scope const(ubyte)[] header, scope const(ubyte)[] body_, long now) @safe pure nothrow
{
    bool allEmpty = true;
    foreach (c; header)
        if (c != ' ')
        {
            allEmpty = false;
            break;
        }
    if (allEmpty)
        return VerifyResult(VerifyStatus.missingSignature);

    long t;
    if (!parseCanonicalInt(ts, t))
        return VerifyResult(VerifyStatus.invalidTimestamp);
    if (now - t > toleranceSeconds)
        return VerifyResult(VerifyStatus.timestampTooOld);
    if (t - now > toleranceSeconds)
        return VerifyResult(VerifyStatus.timestampTooNew);

    // Pre-process every token once; only `v1,<32 decoded bytes>` can match.
    Candidate[] candidates;
    size_t tokenIndex = 0;
    size_t start = 0;
    while (true)
    {
        size_t end = start;
        while (end < header.length && header[end] != ' ')
            end++;
        auto token = header[start .. end];
        size_t comma = 0;
        while (comma < token.length && token[comma] != ',')
            comma++;
        if (comma + 1 <= token.length && comma == 2 && token[0] == 'v' && token[1] == '1')
        {
            auto value = token[comma + 1 .. $];
            if (value.length <= 44)
            {
                ubyte[33] tmp = void;
                if (decodeInto(value, tmp[]) == 32)
                {
                    Candidate c;
                    c.token = tokenIndex;
                    c.digest[] = tmp[0 .. 32];
                    candidates ~= c;
                }
            }
        }
        tokenIndex++;
        if (end == header.length)
            break;
        start = end + 1;
    }

    if (candidates.length != 0)
    {
        foreach (i, ref key; keys)
        {
            immutable expected = signedContentMac(key, id, ts, body_);
            foreach (ref c; candidates)
                if (constantTimeEqual(expected[], c.digest[]))
                    return VerifyResult(VerifyStatus.ok, i, c.token);
        }
    }
    return VerifyResult(VerifyStatus.noMatch);
}
