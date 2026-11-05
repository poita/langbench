/**
 * Line and field handling for the command protocol.
 *
 * Lines are split into fields on single spaces; fields are views into the
 * input buffer.
 */
module webhooks.grammar;

/// The fields of one command line (views into the input).
struct Fields
{
    /// Most fields any valid line has.
    enum maxFields = 8;

    const(ubyte)[][maxFields] item;
    /// Number of fields; `maxFields + 1` means "more than `maxFields`".
    size_t count;
    /// True if some (examined) field was empty.
    bool anyEmpty;

    /// Whether the line has exactly `n` fields, none of them empty.
    bool has(size_t n) const @safe pure nothrow @nogc
    {
        return count == n && !anyEmpty;
    }

    /// Whether field 0 equals `name`.
    bool isCommand(string name) const @safe pure nothrow @nogc
    {
        return count > 0 && equals(item[0], name);
    }
}

/// Whether `a` and the string `b` have the same bytes.
bool equals(scope const(ubyte)[] a, scope const(char)[] b) @trusted pure nothrow @nogc
{
    return a == cast(const(ubyte)[]) b;
}

/// Splits `line` on single spaces.
Fields splitFields(return scope const(ubyte)[] line) @safe pure nothrow @nogc
{
    Fields f;
    size_t start = 0;
    while (true)
    {
        size_t end = start;
        while (end < line.length && line[end] != ' ')
            end++;
        if (f.count == Fields.maxFields)
        {
            f.count = Fields.maxFields + 1;
            break;
        }
        if (end == start)
            f.anyEmpty = true;
        f.item[f.count++] = line[start .. end];
        if (end == line.length)
            break;
        start = end + 1;
    }
    return f;
}

/// True for an empty line or one made only of spaces.
bool isBlank(scope const(ubyte)[] line) @safe pure nothrow @nogc
{
    foreach (c; line)
        if (c != ' ')
            return false;
    return true;
}

/// 1..`maxLen` bytes, all in `0x21..0x7e` (printable ASCII, no space).
bool isPrintableToken(scope const(ubyte)[] s, size_t maxLen) @safe pure nothrow @nogc
{
    if (s.length == 0 || s.length > maxLen)
        return false;
    foreach (c; s)
        if (c < 0x21 || c > 0x7e)
            return false;
    return true;
}

/// 1..64 bytes from `[A-Za-z0-9_.-]`.
bool isName(scope const(ubyte)[] s) @safe pure nothrow @nogc
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
