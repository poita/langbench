/**
 * Lexical helpers for the command stream: line iteration, field splitting
 * and validation of the argument kinds (`<int>`, `<id>`, names, ...).
 *
 * Everything works on byte slices ("views") into the input buffer; nothing
 * here copies input.
 */
module webhooks.grammar;

/// Maximum fields that `splitFields` stores (more are counted, not stored).
enum size_t maxStoredFields = 8;

/// Iterates over the `\n`-separated lines of a buffer without copying.
struct LineReader
{
    private const(ubyte)[] rest;

    this(const(ubyte)[] input) @safe pure nothrow @nogc
    {
        rest = input;
    }

    /// True once all input has been consumed.
    bool empty() const @safe pure nothrow @nogc { return rest.length == 0; }

    /// Returns the next line (without its `\n`). Call only if `!empty`.
    const(ubyte)[] next() @safe pure nothrow @nogc
    in (!empty)
    {
        foreach (i, b; rest)
        {
            if (b == '\n')
            {
                auto line = rest[0 .. i];
                rest = rest[i + 1 .. $];
                return line;
            }
        }
        auto line = rest;
        rest = rest[$ .. $];
        return line;
    }
}

/// True if the line is empty or consists only of spaces.
bool isBlank(scope const(ubyte)[] line) @safe pure nothrow @nogc
{
    foreach (b; line)
        if (b != ' ')
            return false;
    return true;
}

/// The result of splitting a line on single spaces.
struct Fields
{
    const(ubyte)[][maxStoredFields] items;
    /// Total number of fields on the line (may exceed `maxStoredFields`).
    size_t count;
    /// True if any field (including leading/trailing) is empty.
    bool anyEmpty;

    /// The `i`-th field (only valid for `i < min(count, maxStoredFields)`).
    const(ubyte)[] opIndex(size_t i) const @safe pure nothrow @nogc { return items[i]; }
}

/// Splits `line` on single `0x20` characters.
Fields splitFields(const(ubyte)[] line) @safe pure nothrow @nogc
{
    Fields f;
    size_t start = 0;
    foreach (i; 0 .. line.length + 1)
    {
        if (i == line.length || line[i] == ' ')
        {
            auto field = line[start .. i];
            if (field.length == 0)
                f.anyEmpty = true;
            if (f.count < maxStoredFields)
                f.items[f.count] = field;
            ++f.count;
            start = i + 1;
        }
    }
    return f;
}

/// Compares a byte slice with a string literal.
bool equals(scope const(ubyte)[] a, scope string b) @trusted pure nothrow @nogc
{
    return a == cast(const(ubyte)[]) b;
}

private bool allInRange(scope const(ubyte)[] s) @safe pure nothrow @nogc
{
    foreach (b; s)
        if (b < 0x21 || b > 0x7e)
            return false;
    return true;
}

/// `<id>`: 1..256 printable ASCII characters, no space.
bool isId(scope const(ubyte)[] s) @safe pure nothrow @nogc
{
    return s.length >= 1 && s.length <= 256 && allInRange(s);
}

/// A received timestamp field in `verify`: 1..64 printable ASCII characters.
bool isReceivedTimestamp(scope const(ubyte)[] s) @safe pure nothrow @nogc
{
    return s.length >= 1 && s.length <= 64 && allInRange(s);
}

/// `[A-Za-z0-9_.-]` character test.
bool isNameChar(ubyte b) @safe pure nothrow @nogc
{
    return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
        || b == '_' || b == '.' || b == '-';
}

/// `<ep-id>`, `<ev-id>`, `<type>`: 1..64 characters from `[A-Za-z0-9_.-]`.
bool isName(scope const(ubyte)[] s) @safe pure nothrow @nogc
{
    if (s.length < 1 || s.length > 64)
        return false;
    foreach (b; s)
        if (!isNameChar(b))
            return false;
    return true;
}

/// Maximum absolute value of an `<int>`.
enum long maxInt = 1_000_000_000_000_000;

/**
 * Parses a canonical decimal integer: `0`, or an optional `-` followed by a
 * non-zero digit and more digits, absolute value at most 10^15.
 */
bool parseInt(scope const(ubyte)[] s, out long value) @safe pure nothrow @nogc
{
    size_t i = 0;
    bool neg = false;
    if (s.length > 0 && s[0] == '-')
    {
        neg = true;
        i = 1;
    }
    immutable digits = s.length - i;
    if (digits == 0 || digits > 16)
        return false;
    if (s[i] == '0')
    {
        if (digits != 1 || neg)
            return false;
        value = 0;
        return true;
    }
    long v = 0;
    foreach (b; s[i .. $])
    {
        if (b < '0' || b > '9')
            return false;
        v = v * 10 + (b - '0');
    }
    if (v > maxInt)
        return false;
    value = neg ? -v : v;
    return true;
}

/// Splits `s` on `sep` into views (empty entries are kept).
const(ubyte)[][] splitOn(const(ubyte)[] s, ubyte sep) @safe pure nothrow
{
    const(ubyte)[][] parts;
    size_t start = 0;
    foreach (i; 0 .. s.length + 1)
    {
        if (i == s.length || s[i] == sep)
        {
            parts ~= s[start .. i];
            start = i + 1;
        }
    }
    return parts;
}
