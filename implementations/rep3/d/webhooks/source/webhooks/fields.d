/**
 * Validation and parsing of the small scalar grammars used by the command
 * language (integers, identifiers, names) plus byte-splitting helpers.
 *
 * Every function is a single linear pass over its input.
 */
module webhooks.fields;

import webhooks.buffer;

/// Largest absolute value of a canonical integer.
enum long maxAbsInt = 1_000_000_000_000_000;

/**
 * Parse a canonical decimal integer: `0`, or an optional `-` followed by a
 * digit 1-9 and more digits, with absolute value at most 10^15.
 * `+5`, `007`, `-0`, `1e3` etc. are rejected.
 */
bool parseCanonicalInt(Bytes s, out long value) @safe pure nothrow @nogc
{
    size_t i = 0;
    immutable negative = s.length > 0 && s[0] == '-';
    if (negative)
        i = 1;
    immutable digits = s.length - i;
    if (digits == 0 || digits > 16)
        return false;
    if (s[i] == '0')
    {
        if (digits != 1 || negative)
            return false;
        value = 0;
        return true;
    }
    long v = 0;
    foreach (c; s[i .. $])
    {
        if (c < '0' || c > '9')
            return false;
        v = v * 10 + (c - '0');
    }
    if (v > maxAbsInt)
        return false;
    value = negative ? -v : v;
    return true;
}

/// True if `s` is a canonical integer (see `parseCanonicalInt`).
bool isCanonicalInt(Bytes s) @safe pure nothrow @nogc
{
    long ignored;
    return parseCanonicalInt(s, ignored);
}

/// True if every byte of `s` is printable ASCII (0x21..0x7e) and the length is within `1 .. maxLen`.
bool isPrintableToken(Bytes s, size_t maxLen) @safe pure nothrow @nogc
{
    if (s.length == 0 || s.length > maxLen)
        return false;
    foreach (c; s)
        if (c < 0x21 || c > 0x7e)
            return false;
    return true;
}

/// A message id: 1..256 printable ASCII characters, no space.
bool isMessageId(Bytes s) @safe pure nothrow @nogc
{
    return isPrintableToken(s, 256);
}

/// A name (endpoint id, event id, event type): 1..64 characters from `[A-Za-z0-9_.-]`.
bool isName(Bytes s) @safe pure nothrow @nogc
{
    if (s.length == 0 || s.length > 64)
        return false;
    foreach (c; s)
    {
        immutable ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-';
        if (!ok)
            return false;
    }
    return true;
}

/**
 * Split `s` on every occurrence of `sep`, keeping empty pieces.
 *
 * `storage` is scratch space that is grown only when needed and can be reused
 * across calls; the result is a slice of it.
 */
Bytes[] splitOn(Bytes s, ubyte sep, ref Bytes[] storage) @safe pure nothrow
{
    size_t count = 1;
    foreach (c; s)
        if (c == sep)
            ++count;
    if (storage.length < count)
        storage = new Bytes[count];
    size_t n = 0, start = 0;
    foreach (i, c; s)
    {
        if (c == sep)
        {
            storage[n++] = s[start .. i];
            start = i + 1;
        }
    }
    storage[n++] = s[start .. $];
    return storage[0 .. n];
}

/// True if `s` is empty or consists only of spaces.
bool isBlank(Bytes s) @safe pure nothrow @nogc
{
    foreach (c; s)
        if (c != ' ')
            return false;
    return true;
}
