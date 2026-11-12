/**
 * Byte-string helpers.
 *
 * Kiln strings are byte strings.  D's `string` can hold arbitrary bytes, but
 * Phobos' range algorithms would auto-decode it as UTF-8, so everything that
 * touches content goes through these helpers, which only ever index bytes.
 */
module kiln.text;

/// Three-way byte comparison (unsigned bytes; a proper prefix is smaller).
int cmpBytes(const(char)[] a, const(char)[] b) @trusted pure nothrow @nogc
{
    import core.stdc.string : memcmp;

    const n = a.length < b.length ? a.length : b.length;
    if (n)
    {
        const r = memcmp(a.ptr, b.ptr, n);
        if (r != 0)
            return r < 0 ? -1 : 1;
    }
    return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

/// True if `s` starts with `prefix`.
bool startsWithBytes(const(char)[] s, const(char)[] prefix) @safe pure nothrow @nogc
{
    return s.length >= prefix.length && s[0 .. prefix.length] == prefix;
}

/// True if `s` ends with `suffix`.
bool endsWithBytes(const(char)[] s, const(char)[] suffix) @safe pure nothrow @nogc
{
    return s.length >= suffix.length && s[$ - suffix.length .. $] == suffix;
}

/// Index of the first occurrence of `needle` in `hay` at or after `from`, or -1.
ptrdiff_t findBytes(const(char)[] hay, const(char)[] needle, size_t from = 0) @safe pure nothrow @nogc
{
    if (needle.length == 0)
        return from <= hay.length ? cast(ptrdiff_t) from : -1;
    if (hay.length < needle.length)
        return -1;
    const last = hay.length - needle.length;
    const first = needle[0];
    for (size_t i = from; i <= last; ++i)
    {
        if (hay[i] != first)
            continue;
        if (hay[i .. i + needle.length] == needle)
            return cast(ptrdiff_t) i;
    }
    return -1;
}

/// True if `needle` occurs in `hay` (an empty needle always does).
bool containsBytes(const(char)[] hay, const(char)[] needle) @safe pure nothrow @nogc
{
    return findBytes(hay, needle) >= 0;
}

/// Replaces every non-overlapping occurrence of `from` (non-empty) by `to`, scanning left to right.
string replaceAllBytes(const(char)[] s, const(char)[] from, const(char)[] to) @safe pure nothrow
{
    assert(from.length > 0);
    char[] result;
    size_t i = 0;
    while (true)
    {
        const j = findBytes(s, from, i);
        if (j < 0)
        {
            result ~= s[i .. $];
            break;
        }
        result ~= s[i .. j];
        result ~= to;
        i = j + from.length;
    }
    return (() @trusted => cast(string) result)();
}

/// The lines of `content`: split at LF, with one trailing empty piece dropped.
/// The returned slices alias `content`.
string[] splitLines(string content) @safe pure nothrow
{
    string[] lines;
    if (content.length == 0)
        return lines;
    size_t start = 0;
    foreach (i, char c; content)
    {
        if (c == '\n')
        {
            lines ~= content[start .. i];
            start = i + 1;
        }
    }
    if (start < content.length)
        lines ~= content[start .. $];
    return lines;
}

/// Number of lines in `content`.
size_t countLines(const(char)[] content) @safe pure nothrow @nogc
{
    if (content.length == 0)
        return 0;
    size_t n = 0;
    foreach (char c; content)
        if (c == '\n')
            ++n;
    if (content[$ - 1] != '\n')
        ++n;
    return n;
}

/// True for a valid workspace path (components of `[A-Za-z0-9_.+-]`, no `.`/`..`).
bool isWorkspacePath(const(char)[] s) @safe pure nothrow @nogc
{
    if (s.length == 0 || s.length > 1024)
        return false;
    size_t start = 0;
    foreach (i; 0 .. s.length + 1)
    {
        if (i == s.length || s[i] == '/')
        {
            const comp = s[start .. i];
            if (comp.length == 0 || comp.length > 255 || comp == "." || comp == "..")
                return false;
            start = i + 1;
        }
        else
        {
            const c = s[i];
            const ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                || c == '_' || c == '.' || c == '+' || c == '-';
            if (!ok)
                return false;
        }
    }
    return true;
}

/// True if `s` matches `[A-Za-z_][A-Za-z0-9_]*`.
bool isIdentShaped(const(char)[] s) @safe pure nothrow @nogc
{
    if (s.length == 0)
        return false;
    foreach (i, char c; s)
    {
        const alpha = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
        const digit = c >= '0' && c <= '9';
        if (!(alpha || (i > 0 && digit)))
            return false;
    }
    return true;
}

/// True if the first path component of `p` is exactly `out`.
bool isGeneratedPath(const(char)[] p) @safe pure nothrow @nogc
{
    return p == "out" || startsWithBytes(p, "out/");
}

/// Escapes `s` for the canonical command string (without the surrounding quotes).
string escapeForCommand(const(char)[] s) @safe pure nothrow
{
    static immutable hex = "0123456789abcdef";
    char[] r;
    foreach (char c; s)
    {
        switch (c)
        {
        case '\\': r ~= `\\`; break;
        case '"': r ~= `\"`; break;
        case '\n': r ~= `\n`; break;
        case '\t': r ~= `\t`; break;
        case '\r': r ~= `\r`; break;
        default:
            if (c < 0x20 || c == 0x7f)
            {
                r ~= `\x`;
                r ~= hex[(c >> 4) & 0xf];
                r ~= hex[c & 0xf];
            }
            else
                r ~= c;
        }
    }
    return (() @trusted => cast(string) r)();
}

unittest
{
    assert(splitLines("a\nb\n") == ["a", "b"]);
    assert(splitLines("a\nb") == ["a", "b"]);
    assert(splitLines("a\n\nb\n") == ["a", "", "b"]);
    assert(splitLines("\n") == [""]);
    assert(splitLines("").length == 0);
    assert(countLines("a\r\nb") == 2);
}

unittest
{
    assert(replaceAllBytes("aaa", "aa", "b") == "ba");
    assert(replaceAllBytes("abc", "x", "y") == "abc");
    assert(findBytes("hello", "") == 0);
    assert(findBytes("hello", "lo") == 3);
    assert(findBytes("hello", "z") == -1);
    assert(cmpBytes("a", "ab") < 0 && cmpBytes("b", "ab") > 0 && cmpBytes("\xc3", "a") > 0);
}

unittest
{
    assert(isWorkspacePath("src/a.txt"));
    assert(isWorkspacePath("..."));
    assert(!isWorkspacePath(""));
    assert(!isWorkspacePath("/a"));
    assert(!isWorkspacePath("a/"));
    assert(!isWorkspacePath("a//b"));
    assert(!isWorkspacePath("a/../b"));
    assert(!isWorkspacePath("a b"));
    assert(!isWorkspacePath("a@b"));
    assert(isIdentShaped("_x1") && !isIdentShaped("1x") && !isIdentShaped(""));
    assert(isGeneratedPath("out") && isGeneratedPath("out/x") && !isGeneratedPath("output/x"));
    assert(escapeForCommand("a\"\\\n\x01\x7f\xc3") == "a\\\"\\\\\\n\\x01\\x7f\xc3");
}
