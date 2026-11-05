/**
 * The Standard Webhooks signature scheme: secrets, signing and verification.
 */
module webhooks.signature;

import webhooks.base64;
import webhooks.buffer;
import webhooks.grammar;
import webhooks.hmac;

/// Maximum secrets per `<secrets>` field.
enum size_t maxSecrets = 16;
/// Allowed clock skew, in seconds, in either direction (inclusive).
enum long timestampTolerance = 300;

private immutable ubyte[6] secretPrefix = ['w', 'h', 's', 'e', 'c', '_'];

/// A parsed secret: the raw key and its precomputed HMAC key object.
struct Secret
{
    ubyte[] key;
    HmacKey mac;
}

/**
 * Parses one `<secret>` (1..512 characters from 0x21..0x7e excluding `,`,
 * optional single `whsec_` prefix, Base64 remainder decoding to >= 1 byte).
 */
bool parseSecret(scope const(ubyte)[] text, out Secret secret) @safe pure nothrow
{
    if (text.length < 1 || text.length > 512)
        return false;
    foreach (b; text)
        if (b < 0x21 || b > 0x7e || b == ',')
            return false;
    if (text.length >= secretPrefix.length && text[0 .. secretPrefix.length] == secretPrefix[])
        text = text[secretPrefix.length .. $];
    ubyte[] raw;
    if (!decode(text, raw) || raw.length == 0)
        return false;
    secret.key = raw;
    secret.mac = HmacKey(raw);
    return true;
}

/// Parses a `<secrets>` field: 1..16 comma-separated secrets.
bool parseSecrets(const(ubyte)[] field, out Secret[] secrets) @safe pure nothrow
{
    // Count first so a huge comma list is rejected without parsing it.
    size_t commas = 0;
    foreach (b; field)
        if (b == ',')
            ++commas;
    if (commas + 1 > maxSecrets)
        return false;
    auto result = new Secret[commas + 1];
    size_t idx = 0;
    size_t start = 0;
    foreach (i; 0 .. field.length + 1)
    {
        if (i == field.length || field[i] == ',')
        {
            if (!parseSecret(field[start .. i], result[idx++]))
                return false;
            start = i + 1;
        }
    }
    secrets = result;
    return true;
}

private immutable ubyte[1] dot = ['.'];

/// MAC over `id "." timestamp "." body`, streamed (never concatenated).
ubyte[32] signedContentMac(ref const HmacKey key, scope const(ubyte)[] id,
    scope const(ubyte)[] timestamp, scope const(ubyte)[] body_) @safe pure nothrow @nogc
{
    auto s = key.start();
    s.put(id);
    s.put(dot[]);
    s.put(timestamp);
    s.put(dot[]);
    s.put(body_);
    return s.finish();
}

/// Appends `v1,<base64(mac)>` to `sink`.
void appendSignature(scope const(ubyte)[] mac, ref ByteSink sink) @safe pure nothrow
{
    sink.put("v1,");
    encodeStandard(mac, sink);
}

/**
 * Appends the `webhook-signature` header value for `secrets` to `sink`:
 * one `v1,<sig>` per secret in order, separated by single spaces.
 */
void signHeader(const Secret[] secrets, scope const(ubyte)[] id, scope const(ubyte)[] timestamp,
    scope const(ubyte)[] body_, ref ByteSink sink) @safe pure nothrow
{
    foreach (i, ref s; secrets)
    {
        if (i != 0)
            sink.putChar(' ');
        appendSignature(signedContentMac(s.mac, id, timestamp, body_)[], sink);
    }
}

/// Why verification failed.
enum VerifyFailure
{
    none,
    missingSignature,
    invalidTimestamp,
    timestampTooOld,
    timestampTooNew,
    noMatch,
}

/// The wire name of a failure reason (e.g. `no-match`).
string failureName(VerifyFailure f) @safe pure nothrow @nogc
{
    final switch (f)
    {
    case VerifyFailure.none: return "none";
    case VerifyFailure.missingSignature: return "missing-signature";
    case VerifyFailure.invalidTimestamp: return "invalid-timestamp";
    case VerifyFailure.timestampTooOld: return "timestamp-too-old";
    case VerifyFailure.timestampTooNew: return "timestamp-too-new";
    case VerifyFailure.noMatch: return "no-match";
    }
}

/// Outcome of `verify`.
struct VerifyResult
{
    bool ok;
    /// Index of the matching secret (valid if `ok`).
    size_t secretIndex;
    /// Index of the matching header token (valid if `ok`).
    size_t tokenIndex;
    /// Failure reason (valid if `!ok`).
    VerifyFailure failure;
}

private struct Candidate
{
    size_t token;
    ubyte[32] mac;
}

/**
 * Verifies a received webhook.
 *
 * Params:
 *   secrets   = active secrets in order
 *   id        = received `webhook-id`
 *   timestamp = received `webhook-timestamp` text
 *   header    = received `webhook-signature` value
 *   body_     = received body
 *   now       = current Unix time in seconds
 */
VerifyResult verify(const Secret[] secrets, scope const(ubyte)[] id, scope const(ubyte)[] timestamp,
    scope const(ubyte)[] header, scope const(ubyte)[] body_, long now) @safe pure nothrow
{
    VerifyResult fail(VerifyFailure f)
    {
        VerifyResult r;
        r.failure = f;
        return r;
    }

    // 1. Split the header on spaces.
    bool anyToken = false;
    foreach (b; header)
        if (b != ' ')
        {
            anyToken = true;
            break;
        }
    if (!anyToken)
        return fail(VerifyFailure.missingSignature);

    // 2. Canonical timestamp.
    long ts;
    if (!parseInt(timestamp, ts))
        return fail(VerifyFailure.invalidTimestamp);

    // 3. Tolerance window.
    if (now - ts > timestampTolerance)
        return fail(VerifyFailure.timestampTooOld);
    if (ts - now > timestampTolerance)
        return fail(VerifyFailure.timestampTooNew);

    // 4. Pre-decode each token once; keep only v1 tokens that decode to 32 bytes.
    Candidate[] candidates;
    size_t tokenIndex = 0;
    size_t start = 0;
    foreach (i; 0 .. header.length + 1)
    {
        if (i != header.length && header[i] != ' ')
            continue;
        auto token = header[start .. i];
        start = i + 1;
        immutable j = tokenIndex++;
        size_t comma = 0;
        while (comma < token.length && token[comma] != ',')
            ++comma;
        if (comma == token.length || comma != 2 || token[0] != 'v' || token[1] != '1')
            continue;
        auto value = token[comma + 1 .. $];
        // 32 bytes need exactly 43 Base64 characters (plus up to 1 '=').
        if (value.length < 43 || value.length > 44)
            continue;
        ubyte[48] buf = void;
        immutable n = decodeInto(value, buf[]);
        if (n != 32)
            continue;
        Candidate c;
        c.token = j;
        c.mac[] = buf[0 .. 32];
        candidates ~= c;
    }

    if (candidates.length != 0)
    {
        foreach (si, ref s; secrets)
        {
            immutable expected = signedContentMac(s.mac, id, timestamp, body_);
            foreach (ref c; candidates)
            {
                if (c.mac == expected)
                {
                    VerifyResult r;
                    r.ok = true;
                    r.secretIndex = si;
                    r.tokenIndex = c.token;
                    return r;
                }
            }
        }
    }
    return fail(VerifyFailure.noMatch);
}
