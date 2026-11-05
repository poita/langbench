/**
 * Webhook secrets: `whsec_`-prefixed (or bare) Base64 keys.
 */
module webhooks.secret;

import webhooks.base64;
import webhooks.hmac;

/// Longest secret accepted by `parseSecretField`.
enum maxSecretLength = 512;
/// Most secrets accepted in one comma-separated list.
enum maxSecrets = 16;

private immutable ubyte[6] prefix = ['w', 'h', 's', 'e', 'c', '_'];

/**
 * Decodes a secret to its raw HMAC key.
 *
 * A leading `whsec_` is removed once; the rest is Base64-decoded. The secret
 * is invalid if that is not valid Base64 or decodes to nothing.
 *
 * Params:
 *   secret = the secret text
 *   key = receives the raw key bytes
 * Returns: whether the secret is valid.
 */
bool decodeSecret(scope const(ubyte)[] secret, out ubyte[] key) @safe pure nothrow
{
    if (secret.length >= prefix.length && secret[0 .. prefix.length] == prefix[])
        secret = secret[prefix.length .. $];
    ubyte[] k;
    if (!decode(secret, k) || k.length == 0)
        return false;
    key = k;
    return true;
}

/// As `decodeSecret`, but additionally enforces the protocol field grammar:
/// 1..512 bytes in `0x21..0x7e`, excluding `,`.
bool parseSecretField(scope const(ubyte)[] field, out ubyte[] key) @safe pure nothrow
{
    if (field.length == 0 || field.length > maxSecretLength)
        return false;
    foreach (c; field)
        if (c < 0x21 || c > 0x7e || c == ',')
            return false;
    return decodeSecret(field, key);
}

/**
 * Parses a comma-separated list of 1..16 secrets into HMAC keys.
 *
 * Returns: `false` on an empty entry, too many entries, or an invalid secret.
 */
bool parseSecretList(scope const(ubyte)[] field, out HmacKey[] keys) @safe pure nothrow
{
    HmacKey[] result;
    size_t start = 0;
    while (true)
    {
        size_t end = start;
        while (end < field.length && field[end] != ',')
            end++;
        if (result.length == maxSecrets)
            return false;
        ubyte[] raw;
        if (!parseSecretField(field[start .. end], raw))
            return false;
        result ~= HmacKey(raw);
        if (end == field.length)
            break;
        start = end + 1;
    }
    keys = result;
    return true;
}
