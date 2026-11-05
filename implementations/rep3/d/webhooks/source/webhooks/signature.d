/**
 * The Standard Webhooks signature scheme: signing and verification.
 *
 * The signed content is `id "." timestamp "." body`; the signature is
 * `"v1," ~ base64(HMAC-SHA256(key, content))`. With several active secrets the
 * header carries one signature per secret joined by single spaces.
 */
module webhooks.signature;

import webhooks.base64;
import webhooks.buffer;
import webhooks.fields;
import webhooks.hmac;

/// Allowed clock skew, in seconds, in either direction (inclusive).
enum long toleranceSeconds = 300;

private immutable Bytes dot = asBytes(".");

/// MAC of the signed content `id.ts.body`, streamed without concatenating.
ubyte[32] signedMac(ref const HmacKey key, Bytes id, Bytes ts, Bytes body_) @safe pure nothrow @nogc
{
    return key.mac(id, dot, ts, dot, body_);
}

/**
 * Append the `webhook-signature` header value for the given keys to `output`:
 * one `v1,<base64>` per key, separated by single spaces.
 */
void putSignatureHeader(ref OutBuffer output, const HmacKey[] keys, Bytes id, Bytes ts, Bytes body_)
    @safe pure nothrow
{
    foreach (i, ref key; keys)
    {
        if (i > 0)
            output.put(cast(ubyte) ' ');
        output.put("v1,");
        putStandard(output, signedMac(key, id, ts, body_)[]);
    }
}

/// The `webhook-signature` header value for `keys` over `id`, `ts` (decimal text) and `body_`.
string sign(const HmacKey[] keys, Bytes id, Bytes ts, Bytes body_) @safe pure nothrow
{
    OutBuffer o;
    putSignatureHeader(o, keys, id, ts, body_);
    return o.toString();
}

/// Outcome category of `verify`.
enum VerifyStatus
{
    ok,
    missingSignature,
    invalidTimestamp,
    timestampTooOld,
    timestampTooNew,
    noMatch,
}

/// Result of `verify`. `secretIndex` and `tokenIndex` are meaningful only when `status == ok`.
struct VerifyResult
{
    VerifyStatus status;
    size_t secretIndex;
    size_t tokenIndex;
}

/// The failure reason keyword for a status (`"ok"` for success).
string reason(VerifyStatus s) @safe pure nothrow @nogc
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

/**
 * Verify a received webhook.
 *
 * Params:
 *   keys   = active secrets, in order
 *   id     = received `webhook-id`
 *   ts     = received `webhook-timestamp` text (need not be canonical)
 *   now    = current Unix time in seconds
 *   header = received `webhook-signature` value
 *   body_  = received body
 *
 * The checks run in a fixed order and stop at the first that decides:
 * missing signature, timestamp syntax, timestamp tolerance, then signature
 * match (first matching secret, then first matching header token).
 */
VerifyResult verify(const HmacKey[] keys, Bytes id, Bytes ts, long now, Bytes header, Bytes body_)
    @safe pure nothrow
{
    // Step 1: split on single spaces; all-empty tokens means no signature.
    Bytes[] storage;
    auto tokens = splitOn(header, ' ', storage);
    bool anyToken = false;
    foreach (t; tokens)
        if (t.length > 0)
        {
            anyToken = true;
            break;
        }
    if (!anyToken)
        return VerifyResult(VerifyStatus.missingSignature);

    // Step 2: canonical timestamp.
    long tsValue;
    if (!parseCanonicalInt(ts, tsValue))
        return VerifyResult(VerifyStatus.invalidTimestamp);

    // Step 3: tolerance (inclusive).
    if (now - tsValue > toleranceSeconds)
        return VerifyResult(VerifyStatus.timestampTooOld);
    if (tsValue - now > toleranceSeconds)
        return VerifyResult(VerifyStatus.timestampTooNew);

    // Step 4: decode every token once. A token can only match if it is
    // `v1,<value>` with a value that decodes to exactly 32 bytes; such a value
    // is 43 characters, or 44 with its single `=` of padding.
    static struct Candidate
    {
        bool usable;
        ubyte[32] digest;
    }

    auto candidates = new Candidate[tokens.length];
    ubyte[33] scratch;
    foreach (j, token; tokens)
    {
        size_t comma = 0;
        while (comma < token.length && token[comma] != ',')
            ++comma;
        if (comma == token.length)
            continue;
        if (token[0 .. comma] != asBytes("v1"))
            continue;
        auto value = token[comma + 1 .. $];
        if (value.length != 43 && value.length != 44)
            continue;
        immutable n = decodeInto(value, scratch[]);
        if (n != 32)
            continue;
        candidates[j].usable = true;
        candidates[j].digest[] = scratch[0 .. 32];
    }

    foreach (i, ref key; keys)
    {
        immutable expected = signedMac(key, id, ts, body_);
        foreach (j, ref c; candidates)
            if (c.usable && constantTimeEqual(c.digest[], expected[]))
                return VerifyResult(VerifyStatus.ok, i, j);
    }
    return VerifyResult(VerifyStatus.noMatch);
}

private bool constantTimeEqual(const(ubyte)[] a, const(ubyte)[] b) @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    ubyte diff = 0;
    foreach (i; 0 .. a.length)
        diff |= a[i] ^ b[i];
    return diff == 0;
}
