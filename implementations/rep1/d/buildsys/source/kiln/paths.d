/// Workspace path validation and the reserved-tree predicates.
module kiln.paths;

/// Name of the persisted build-state file.
enum stateFileName = ".kiln-state";

/// True if `c` may appear inside a path component.
bool isPathChar(char c) pure nothrow @nogc @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '_' || c == '.' || c == '+' || c == '-';
}

/// True if `s` is a valid workspace path.
bool isWorkspacePath(const(char)[] s) pure nothrow @nogc @safe
{
    if (s.length == 0 || s.length > 1024)
        return false;
    size_t start = 0;
    foreach (i; 0 .. s.length + 1)
    {
        if (i == s.length || s[i] == '/')
        {
            const len = i - start;
            if (len == 0 || len > 255)
                return false;
            if (len == 1 && s[start] == '.')
                return false;
            if (len == 2 && s[start] == '.' && s[start + 1] == '.')
                return false;
            start = i + 1;
        }
        else if (!isPathChar(s[i]))
            return false;
    }
    return true;
}

/// True if the first component of `p` is exactly `out`.
bool isOutPath(const(char)[] p) pure nothrow @nogc @safe
{
    return p == "out" || (p.length > 3 && p[0 .. 4] == "out/");
}

/// True if `glob` may match `p` (not generated, not the state file).
bool isGlobEligible(const(char)[] p) pure nothrow @nogc @safe
{
    return !isOutPath(p) && p != stateFileName;
}

/// True if `s` is `[A-Za-z_][A-Za-z0-9_]*`.
bool isIdentShaped(const(char)[] s) pure nothrow @nogc @safe
{
    if (s.length == 0)
        return false;
    foreach (i, c; s)
    {
        const alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
        const digit = c >= '0' && c <= '9';
        if (!(alpha || (i > 0 && digit)))
            return false;
    }
    return true;
}

/// True if `s` is `@` followed by an identifier-shaped name.
bool isPhonyRef(const(char)[] s) pure nothrow @nogc @safe
{
    return s.length > 1 && s[0] == '@' && isIdentShaped(s[1 .. $]);
}
