/// Small string helpers shared by the header parsers.
///
/// All text in this library is handled as UTF-8 `string`s; every delimiter
/// the specification cares about is ASCII, so scanning is done byte-wise.
module mime.text;

import std.array : appender;

@safe:

/// True for SPACE and TAB.
bool isBlank(char c) pure nothrow @nogc { return c == ' ' || c == '\t'; }

/// Strips leading and trailing SPACE and TAB.
string stripBlanks(string s) pure nothrow @nogc
{
    size_t a = 0, b = s.length;
    while (a < b && isBlank(s[a])) ++a;
    while (b > a && isBlank(s[b - 1])) --b;
    return s[a .. b];
}

/// Replaces each maximal run of SPACE/TAB with one SPACE, then strips a
/// leading and a trailing SPACE.
string collapse(string s) pure nothrow
{
    auto app = appender!string();
    bool pendingSpace = false;
    foreach (char c; s)
    {
        if (isBlank(c))
        {
            pendingSpace = true;
            continue;
        }
        if (pendingSpace && app.data.length != 0)
            app.put(' ');
        pendingSpace = false;
        app.put(c);
    }
    return app.data;
}

/// Lower-cases ASCII letters only.
string toLowerAscii(string s) pure nothrow
{
    bool needs = false;
    foreach (char c; s)
        if (c >= 'A' && c <= 'Z')
        {
            needs = true;
            break;
        }
    if (!needs)
        return s;
    auto r = new char[s.length];
    foreach (i, char c; s)
        r[i] = (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
    return (() @trusted => cast(string) r)();
}

/// Compares ASCII case-insensitively.
bool equalsIgnoreCase(string a, string b) pure nothrow
{
    return toLowerAscii(a) == toLowerAscii(b);
}

/// Skips a parenthesised comment starting at `s[i] == '('`.  Nesting is
/// counted and `\` escapes the next character; an unterminated comment runs
/// to the end.  Returns the index just after the comment.
size_t skipComment(string s, size_t i) pure nothrow @nogc
{
    assert(i < s.length && s[i] == '(');
    int depth = 0;
    while (i < s.length)
    {
        const c = s[i];
        if (c == '\\')
        {
            i += 2;
            continue;
        }
        ++i;
        if (c == '(')
            ++depth;
        else if (c == ')' && --depth == 0)
            return i;
    }
    return s.length;
}

/// Reads a quoted string whose opening `"` is at `s[i]`.  `\` and the
/// character after it stand for that character; an unterminated string runs
/// to the end; a trailing `\` stands for itself.  Sets `end` to the index
/// just after the closing quote and returns the unescaped contents.
string readQuoted(string s, size_t i, out size_t end) pure nothrow
{
    assert(i < s.length && s[i] == '"');
    ++i;
    const begin = i;
    bool escaped = false;
    size_t j = i;
    while (j < s.length && s[j] != '"')
    {
        if (s[j] == '\\' && j + 1 < s.length)
        {
            escaped = true;
            j += 2;
        }
        else
            ++j;
    }
    end = j < s.length ? j + 1 : s.length;
    if (!escaped)
        return s[begin .. j];
    auto app = appender!string();
    for (size_t k = begin; k < j; ++k)
    {
        if (s[k] == '\\' && k + 1 < j)
            ++k;
        app.put(s[k]);
    }
    return app.data;
}

pure nothrow unittest
{
    assert(collapse("  a \t b  ") == "a b");
    assert(collapse("") == "");
    assert(collapse(" \t ") == "");
    assert(stripBlanks(" \tx y\t") == "x y");
    assert(toLowerAscii("AbÉ") == "abÉ");
    size_t e;
    assert(readQuoted(`"a\\" x`, 0, e) == `a\` && e == 5);
    assert(readQuoted(`"abc`, 0, e) == "abc" && e == 4);
    assert(readQuoted(`"a\`, 0, e) == `a\` && e == 3);
    assert(skipComment("(a (b) \\) c) d", 0) == 12);
    assert(skipComment("(open", 0) == 5);
}
