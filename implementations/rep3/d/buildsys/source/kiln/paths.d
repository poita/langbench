/// Workspace path rules.
module kiln.paths;

/// True for the bytes allowed inside a path component.
bool isPathChar(char c) @safe pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '_' || c == '.' || c == '+' || c == '-';
}

/// True when `p` is a valid workspace path: non-empty `/`-separated components
/// of 1..255 path characters, none of them `.` or `..`, at most 1024 bytes.
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
            auto comp = p[start .. i];
            if (comp == "." || comp == "..")
                return false;
            start = i + 1;
        }
        else if (!isPathChar(p[i]))
            return false;
    }
    return true;
}

/// True when `s` matches `[A-Za-z_][A-Za-z0-9_]*`.
bool isIdentShaped(const(char)[] s) @safe pure nothrow @nogc
{
    if (s.length == 0)
        return false;
    foreach (i, c; s)
    {
        immutable alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
        if (!(alpha || (i > 0 && c >= '0' && c <= '9')))
            return false;
    }
    return true;
}

/// True when the first component of `p` is exactly `out` (a generated path).
bool isGeneratedPath(const(char)[] p) @safe pure nothrow @nogc
{
    return p == "out" || (p.length > 3 && p[0 .. 4] == "out/");
}

/// The state file's workspace path.
enum stateFilePath = ".kiln-state";

/// True when `glob` may return `p` (not generated, not the state file).
bool isGlobEligible(const(char)[] p) @safe pure nothrow @nogc
{
    return !isGeneratedPath(p) && p != stateFilePath;
}

/// A reference in `in`/`after`/`phony` deps is either `@name` (identifier
/// shaped) or a workspace path.
bool isReferenceShape(const(char)[] r) @safe pure nothrow @nogc
{
    if (r.length > 0 && r[0] == '@')
        return isIdentShaped(r[1 .. $]);
    return isWorkspacePath(r);
}
