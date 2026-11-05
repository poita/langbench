/**
 * Webhook secrets: `whsec_`-prefixed (optionally) Base64 keys.
 */
module webhooks.secret;

import webhooks.base64;
import webhooks.buffer;
import webhooks.fields;
import webhooks.hmac;

/// The optional prefix of a secret.
enum string secretPrefix = "whsec_";
/// Maximum characters in one secret.
enum size_t maxSecretLength = 512;
/// Maximum secrets in a comma-separated list.
enum size_t maxSecrets = 16;

/**
 * Decode one secret into its raw key bytes.
 *
 * The secret must be 1..512 printable ASCII characters other than `,`. A
 * single leading `whsec_` is removed; the rest must be valid Base64 (§1.3 of
 * the spec) decoding to at least one byte.
 *
 * Returns: `false` if the secret is invalid.
 */
bool decodeSecret(Bytes secret, out ubyte[] key) @safe pure nothrow
{
    if (!isPrintableToken(secret, maxSecretLength))
        return false;
    foreach (c; secret)
        if (c == ',')
            return false;
    auto rest = secret;
    immutable prefix = asBytes(secretPrefix);
    if (rest.length >= prefix.length && rest[0 .. prefix.length] == prefix)
        rest = rest[prefix.length .. $];
    ubyte[] raw;
    if (!decode(rest, raw) || raw.length == 0)
        return false;
    key = raw;
    return true;
}

/**
 * Parse a comma-separated list of 1..16 secrets into prepared HMAC keys
 * (in order).
 *
 * Returns: `false` on an empty entry, more than 16 entries, or any invalid secret.
 */
bool parseSecrets(Bytes list, out HmacKey[] keys) @safe pure nothrow
{
    // Count first so an oversized list is rejected without decoding anything.
    size_t count = 1;
    foreach (c; list)
        if (c == ',')
            ++count;
    if (count > maxSecrets)
        return false;
    auto result = new HmacKey[count];
    size_t start = 0, n = 0;
    foreach (i; 0 .. list.length + 1)
    {
        if (i == list.length || list[i] == ',')
        {
            ubyte[] key;
            if (!decodeSecret(list[start .. i], key))
                return false;
            result[n++] = HmacKey(key);
            start = i + 1;
        }
    }
    keys = result;
    return true;
}
