/**
 * Validation of the argument kinds used by the command protocol: fields,
 * identifiers, names, integers and secret lists.
 *
 * All functions work on bytes; every grammar involved is ASCII-only.
 */
module webhooks.fields;

import webhooks.secret;
import webhooks.signature : parseCanonicalInt;

/// Longest secret, in characters.
enum size_t maxSecretLength = 512;
/// Most secrets in a `<secrets>` field.
enum size_t maxSecrets = 16;
/// Longest `<id>`.
enum size_t maxIdLength = 256;
/// Longest name (endpoint id, event id, event type).
enum size_t maxNameLength = 64;

/// Line reader over a byte buffer: yields the non-blank lines of the input.
struct LineReader
{
    private const(ubyte)[] rest;

    this(const(ubyte)[] input) pure nothrow @safe @nogc
    {
        rest = input;
    }

    /// Fetches the next line that is neither empty nor all spaces.
    /// Returns `false` at end of input. The terminating `\n` is not included.
    bool next(out const(ubyte)[] line) pure nothrow @safe @nogc
    {
        while (rest.length > 0)
        {
            size_t end = 0;
            while (end < rest.length && rest[end] != '\n')
                ++end;
            auto candidate = rest[0 .. end];
            rest = end < rest.length ? rest[end + 1 .. $] : rest[$ .. $];
            if (!isBlank(candidate))
            {
                line = candidate;
                return true;
            }
        }
        return false;
    }
}

private bool isBlank(scope const(ubyte)[] line) pure nothrow @safe @nogc
{
    foreach (c; line)
        if (c != ' ')
            return false;
    return true;
}

/**
 * Splits `line` on single spaces into at most `limit` fields.
 *
 * Returns: `false` if any field is empty (two adjacent, leading or trailing
 * spaces) or there are more than `limit` fields; `fields` is then unspecified.
 */
bool splitFields(const(ubyte)[] line, size_t limit, out const(ubyte)[][] fields) pure nothrow @safe
{
    const(ubyte)[][] result;
    size_t start = 0;
    foreach (i; 0 .. line.length + 1)
    {
        if (i == line.length || line[i] == ' ')
        {
            if (i == start || result.length == limit)
                return false;
            result ~= line[start .. i];
            start = i + 1;
        }
    }
    fields = result;
    return true;
}

/// `true` for a printable ASCII character other than space (0x21..0x7e).
bool isGraphic(ubyte c) pure nothrow @safe @nogc
{
    return c >= 0x21 && c <= 0x7e;
}

/// 1..`maxLength` printable ASCII characters, no space.
bool isGraphicField(scope const(ubyte)[] f, size_t maxLength) pure nothrow @safe @nogc
{
    if (f.length == 0 || f.length > maxLength)
        return false;
    foreach (c; f)
        if (!isGraphic(c))
            return false;
    return true;
}

/// A webhook `<id>`: 1..256 printable ASCII characters.
bool isId(scope const(ubyte)[] f) pure nothrow @safe @nogc
{
    return isGraphicField(f, maxIdLength);
}

/// A name from `[A-Za-z0-9_.-]`, 1..64 characters (endpoint ids, event ids, types).
bool isName(scope const(ubyte)[] f) pure nothrow @safe @nogc
{
    if (f.length == 0 || f.length > maxNameLength)
        return false;
    foreach (c; f)
    {
        immutable ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
            || c == '_' || c == '.' || c == '-';
        if (!ok)
            return false;
    }
    return true;
}

/// A canonical `<int>` (see `webhooks.signature.parseCanonicalInt`).
bool parseInt(scope const(ubyte)[] f, out long value) pure nothrow @safe @nogc
{
    return parseCanonicalInt(f, value);
}

/// Parses one `<secret>`: 1..512 printable characters, no comma, valid per
/// `Secret.parse`.
bool parseSecretField(scope const(ubyte)[] f, out Secret secret) pure nothrow @trusted
{
    if (!isGraphicField(f, maxSecretLength))
        return false;
    foreach (c; f)
        if (c == ',')
            return false;
    return Secret.parse(cast(const(char)[]) f, secret);
}

/// Parses a `<secrets>` field: 1..16 comma-separated secrets.
bool parseSecretsField(scope const(ubyte)[] f, out Secret[] secrets) pure nothrow @safe
{
    Secret[] result;
    size_t start = 0;
    foreach (i; 0 .. f.length + 1)
    {
        if (i == f.length || f[i] == ',')
        {
            if (result.length == maxSecrets)
                return false;
            Secret s;
            if (!parseSecretField(f[start .. i], s))
                return false;
            result ~= s;
            start = i + 1;
        }
    }
    secrets = result;
    return true;
}

/// Splits `f` on commas without any validation of the pieces.
const(ubyte)[][] splitCommas(const(ubyte)[] f) pure nothrow @safe
{
    const(ubyte)[][] result;
    size_t start = 0;
    foreach (i; 0 .. f.length + 1)
    {
        if (i == f.length || f[i] == ',')
        {
            result ~= f[start .. i];
            start = i + 1;
        }
    }
    return result;
}

@safe unittest
{
    const(ubyte)[][] fs;
    assert(splitFields(cast(const(ubyte)[]) "a bc d", 8, fs) && fs.length == 3 && fs[1] == cast(const(ubyte)[]) "bc");
    assert(!splitFields(cast(const(ubyte)[]) "a  b", 8, fs));
    assert(!splitFields(cast(const(ubyte)[]) " a", 8, fs));
    assert(!splitFields(cast(const(ubyte)[]) "a ", 8, fs));
    assert(!splitFields(cast(const(ubyte)[]) "a b c", 2, fs));
    assert(splitFields(cast(const(ubyte)[]) "a\tb", 8, fs) && fs.length == 1);
}

@safe unittest
{
    auto reader = LineReader(cast(const(ubyte)[]) "a\n\n   \nb c\nlast");
    const(ubyte)[] line;
    string[] seen;
    while (reader.next(line))
        seen ~= cast(string) line.idup;
    assert(seen == ["a", "b c", "last"]);
}

@safe unittest
{
    Secret[] s;
    assert(parseSecretsField(cast(const(ubyte)[]) "whsec_c2VjcmV0,whsec_b3RoZXI", s) && s.length == 2);
    assert(!parseSecretsField(cast(const(ubyte)[]) "whsec_c2VjcmV0,", s));
    assert(!parseSecretsField(cast(const(ubyte)[]) ",whsec_c2VjcmV0", s));
    assert(!parseSecretsField(cast(const(ubyte)[]) "whsec_c2VjcmV0,whsec_", s));
    string sixteen = "c2VjcmV0";
    foreach (_; 0 .. 15)
        sixteen ~= ",c2VjcmV0";
    assert(parseSecretsField(cast(const(ubyte)[]) sixteen, s) && s.length == 16);
    assert(!parseSecretsField(cast(const(ubyte)[]) (sixteen ~ ",c2VjcmV0"), s));
    Secret one;
    assert(!parseSecretField(cast(const(ubyte)[]) "a,b", one));
}

@safe unittest
{
    assert(isName(cast(const(ubyte)[]) "user.created-v2_x"));
    assert(!isName(cast(const(ubyte)[]) "a b"));
    assert(!isName(cast(const(ubyte)[]) "*"));
    assert(isId(cast(const(ubyte)[]) "-"));
    assert(!isId(cast(const(ubyte)[]) "a\tb"));
}
