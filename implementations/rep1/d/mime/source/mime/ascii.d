/// Small ASCII helpers shared by the parsers. The whole library scans text as
/// UTF-8 bytes: every syntactic character is ASCII, and no byte of a
/// multi-byte UTF-8 sequence is ASCII, so byte scanning is exact.
module mime.ascii;

/// True for SPACE and TAB.
bool isBlank(char c) @safe pure nothrow @nogc
{
    return c == ' ' || c == '\t';
}

/// True for `0-9`.
bool isDigit(char c) @safe pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

/// Value of a hexadecimal digit (`0-9A-Fa-f`), or -1.
int hexValue(char c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/// Lower-cases ASCII letters only; returns the argument itself when unchanged.
string toLowerAscii(string s) @safe pure nothrow
{
    size_t i = 0;
    for (; i < s.length; i++)
        if (s[i] >= 'A' && s[i] <= 'Z')
            break;
    if (i == s.length)
        return s;
    auto r = s.dup;
    foreach (ref c; r[i .. $])
        if (c >= 'A' && c <= 'Z')
            c += 'a' - 'A';
    return (() @trusted => cast(string) r)();
}

/// Case-insensitive (ASCII) equality of `s` with an already lower-case `lower`.
bool equalsLower(const(char)[] s, string lower) @safe pure nothrow @nogc
{
    if (s.length != lower.length)
        return false;
    foreach (i, c0; s)
    {
        char c = c0;
        if (c >= 'A' && c <= 'Z')
            c += 'a' - 'A';
        if (c != lower[i])
            return false;
    }
    return true;
}

/// Strips leading and trailing SPACE and TAB.
inout(char)[] stripBlanks(inout(char)[] s) @safe pure nothrow @nogc
{
    size_t a = 0, b = s.length;
    while (a < b && isBlank(s[a]))
        a++;
    while (b > a && isBlank(s[b - 1]))
        b--;
    return s[a .. b];
}

/// `collapse(s)`: each maximal run of SPACE/TAB becomes one SPACE, then a
/// leading and a trailing SPACE are stripped.
string collapse(const(char)[] s) @safe pure nothrow
{
    auto r = new char[](s.length);
    size_t n = 0;
    bool inRun = false;
    foreach (c; s)
    {
        if (isBlank(c))
        {
            if (!inRun)
                r[n++] = ' ';
            inRun = true;
        }
        else
        {
            r[n++] = c;
            inRun = false;
        }
    }
    size_t a = 0, b = n;
    if (a < b && r[a] == ' ')
        a++;
    if (b > a && r[b - 1] == ' ')
        b--;
    return (() @trusted => cast(string) r[a .. b])();
}
