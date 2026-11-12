/**
 * Webhook signing secrets (Standard Webhooks, "Secrets").
 */
module webhooks.secret;

import webhooks.base64;
import webhooks.hmac;

/// The prefix a secret may carry; stripped once before Base64 decoding.
enum string secretPrefix = "whsec_";

/**
 * A parsed signing secret: the raw HMAC key, plus an `Hmac` that has already
 * absorbed it so that each message only pays for the message itself.
 */
struct Secret
{
    /// The raw key bytes (never empty).
    immutable(ubyte)[] key;
    /// An HMAC keyed with `key`; copy it to authenticate a message.
    Hmac keyed;

    /**
     * Parses a secret of the form `whsec_<base64>` or plain `<base64>`.
     *
     * The prefix is removed once, so `whsec_whsec_...` decodes the second
     * `whsec_` as Base64 data. A secret whose remainder is not valid Base64,
     * or decodes to no bytes, is rejected.
     *
     * Returns: `true` and fills `secret` on success.
     */
    static bool parse(scope const(char)[] text, out Secret secret) pure nothrow @safe
    {
        if (text.length >= secretPrefix.length && text[0 .. secretPrefix.length] == secretPrefix)
            text = text[secretPrefix.length .. $];
        ubyte[] raw;
        if (!decodeBase64(text, raw) || raw.length == 0)
            return false;
        secret.key = (() @trusted => cast(immutable) raw)();
        secret.keyed = Hmac(secret.key);
        return true;
    }
}

@safe unittest
{
    import webhooks.hex : toHex;

    Secret s;
    assert(Secret.parse("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw", s));
    assert(toHex(s.key) == "31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0");
    Secret t;
    assert(Secret.parse("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw", t));
    assert(t.key == s.key);
    Secret u;
    assert(Secret.parse("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr", u));
    assert(u.key.length == 25);
}

@safe unittest
{
    Secret s;
    assert(!Secret.parse("", s));
    assert(!Secret.parse("whsec_", s)); // decodes to zero bytes
    assert(!Secret.parse("whsec_!!!!", s));
    assert(!Secret.parse("A", s)); // length mod 4 == 1
    // The prefix is stripped once: the second "whsec_" is Base64 data
    // ("whsec_QQQQ" is 10 characters -> 7 bytes).
    assert(Secret.parse("whsec_whsec_QQQQ", s));
    assert(s.key.length == 7);
    assert(!Secret.parse("whsec_whsec_QQ==", s)); // 8-char body, padding invalid
}
