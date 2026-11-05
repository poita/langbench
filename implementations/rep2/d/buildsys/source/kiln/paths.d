/**
 * Workspace path predicates.
 */
module kiln.paths;

private bool isPathChar(char c) @safe pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '_' || c == '.' || c == '+' || c == '-';
}

/// True iff `p` is a valid workspace path (non-empty `/`-joined components of
/// `[A-Za-z0-9_.+-]`, none `.` or `..`, at most 255 bytes each, 1024 in all).
bool isWorkspacePath(const(char)[] p) @safe pure nothrow @nogc
{
    if (p.length == 0 || p.length > 1024)
        return false;
    size_t start = 0;
    foreach (i; 0 .. p.length + 1)
    {
        if (i == p.length || p[i] == '/')
        {
            immutable n = i - start;
            if (n == 0 || n > 255)
                return false;
            const comp = p[start .. i];
            if (comp == "." || comp == "..")
                return false;
            start = i + 1;
        }
        else if (!isPathChar(p[i]))
            return false;
    }
    return true;
}

/// True iff `s` matches `[A-Za-z_][A-Za-z0-9_]*`.
bool isIdentifier(const(char)[] s) @safe pure nothrow @nogc
{
    if (s.length == 0)
        return false;
    foreach (i, c; s)
    {
        immutable alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
        immutable digit = c >= '0' && c <= '9';
        if (!(alpha || (i > 0 && digit)))
            return false;
    }
    return true;
}

/// True iff the first component of `p` is exactly `out`.
bool isGenerated(const(char)[] p) @safe pure nothrow @nogc
{
    return p == "out" || (p.length > 3 && p[0 .. 4] == "out/");
}

/// The name of the persisted state file.
enum stateFileName = ".kiln-state";

/// True iff `glob` may return `p` (not generated and not the state file).
bool isGlobEligible(const(char)[] p) @safe pure nothrow @nogc
{
    return !isGenerated(p) && p != stateFileName;
}
