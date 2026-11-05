/// Lexical helpers shared by the header parsers: quoted strings and comments.
module mime.syntax;

import mime.ascii;

/// Result of scanning a quoted string.
struct Quoted
{
    string text; /// the unescaped contents
    size_t end; /// index just past the closing quote (or the end of the value)
}

/// Scans the quoted string whose opening `"` is at `v[start]`.
///
/// A backslash and the byte after it stand for that byte; an unterminated
/// string extends to the end of the value; a trailing backslash stands for
/// itself.
Quoted scanQuoted(string v, size_t start) @safe pure nothrow
{
    size_t i = start + 1;
    size_t runStart = i;
    char[] buf;
    bool copied = false;
    while (i < v.length)
    {
        immutable c = v[i];
        if (c == '"')
        {
            string t = copied ? (() @trusted => cast(string)(buf ~ v[runStart .. i]))() : v[runStart .. i];
            return Quoted(t, i + 1);
        }
        if (c == '\\' && i + 1 < v.length)
        {
            buf ~= v[runStart .. i];
            copied = true;
            buf ~= v[i + 1];
            i += 2;
            runStart = i;
            continue;
        }
        i++;
    }
    string t = copied ? (() @trusted => cast(string)(buf ~ v[runStart .. $]))() : v[runStart .. $];
    return Quoted(t, v.length);
}

/// Returns the index just past the comment whose `(` is at `v[start]`.
/// Comments nest, a backslash escapes the next byte, and an unterminated
/// comment runs to the end of the value.
size_t skipComment(const(char)[] v, size_t start) @safe pure nothrow @nogc
{
    size_t depth = 0;
    size_t i = start;
    while (i < v.length)
    {
        immutable c = v[i];
        if (c == '\\')
        {
            i += 2;
            continue;
        }
        if (c == '(')
            depth++;
        else if (c == ')')
        {
            depth--;
            if (depth == 0)
                return i + 1;
        }
        i++;
    }
    return v.length;
}
