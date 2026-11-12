/// Reference lookup: `HEAD`, loose refs under `refs/` and `packed-refs`.
module gitrepo.refs;

import std.file : exists, isFile, readFile = read;

import gitrepo.objectid;

/// Resolves ref names to object ids.
///
/// A name resolves to the loose file `<repo>/<name>` when it exists, and
/// otherwise to its `packed-refs` entry. Only `HEAD` and names beginning with
/// `refs/` are looked up. Symbolic refs (`ref: <name>`) are followed at most
/// `maxSymrefDepth` times.
final class RefDb
{
    /// How many `ref:` hops are followed before giving up.
    enum maxSymrefDepth = 5;

    private string repoDir;
    private ObjectId[string] packed;

    /// Open the repository directory (the one holding `HEAD` and `refs/`);
    /// `packed-refs` is read once, here.
    this(string repoDir)
    {
        this.repoDir = repoDir;
        loadPacked();
    }

    /// Resolve `name`. Returns false when it is not a valid ref name, does not
    /// exist, or is unreadable or malformed.
    bool resolve(string name, out ObjectId id)
    {
        foreach (hops; 0 .. maxSymrefDepth + 1)
        {
            if (!validRefName(name))
                return false;
            const(ubyte)[] content;
            immutable path = repoDir ~ "/" ~ name;
            if (exists(path) && isFile(path))
            {
                try
                    content = cast(const(ubyte)[]) readFile(path);
                catch (Exception)
                    return false;
            }
            else
            {
                if (auto p = name in packed)
                {
                    id = *p;
                    return true;
                }
                return false;
            }
            while (content.length && isSpace(content[$ - 1]))
                content = content[0 .. $ - 1];
            if (content.length > 5 && content[0 .. 5] == cast(const(ubyte)[]) "ref: ")
            {
                name = cast(string) content[5 .. $].idup;
                continue;
            }
            return isLowerId(cast(const(char)[]) content) && ObjectId.tryParse(cast(const(char)[]) content, id);
        }
        return false; // too many symbolic hops
    }

    private void loadPacked()
    {
        immutable path = repoDir ~ "/packed-refs";
        if (!exists(path) || !isFile(path))
            return;
        const(ubyte)[] text;
        try
            text = cast(const(ubyte)[]) readFile(path);
        catch (Exception)
            return;
        size_t pos;
        while (pos < text.length)
        {
            size_t eol = pos;
            while (eol < text.length && text[eol] != '\n')
                ++eol;
            auto line = text[pos .. eol];
            pos = eol + 1;
            if (line.length == 0 || line[0] == '#' || line[0] == '^')
                continue;
            ObjectId id;
            if (line.length > 41 && line[40] == ' '
                    && ObjectId.tryParse(cast(const(char)[]) line[0 .. 40], id))
                packed[cast(string) line[41 .. $].idup] = id;
        }
    }
}

/// True if `name` is `HEAD` or starts with `refs/`, and has no empty, `.` or
/// `..` component (and no NUL byte).
bool validRefName(scope const(char)[] name) @safe pure nothrow @nogc
{
    if (name != "HEAD" && !(name.length > 5 && name[0 .. 5] == "refs/"))
        return false;
    size_t start = 0;
    foreach (i; 0 .. name.length + 1)
    {
        if (i < name.length && name[i] == 0)
            return false;
        if (i == name.length || name[i] == '/')
        {
            auto comp = name[start .. i];
            if (comp.length == 0 || comp == "." || comp == "..")
                return false;
            start = i + 1;
        }
    }
    return true;
}

private bool isSpace(ubyte c) @safe pure nothrow @nogc
{
    return c == ' ' || (c >= '\t' && c <= '\r');
}

private bool isLowerId(scope const(char)[] s) @safe pure nothrow @nogc
{
    import gitrepo.hex : isLowerHex;

    return s.length == 40 && isLowerHex(s);
}

unittest
{
    assert(validRefName("HEAD"));
    assert(validRefName("refs/heads/main"));
    assert(!validRefName("config"));
    assert(!validRefName("refs/"));
    assert(!validRefName("refs//x"));
    assert(!validRefName("refs/./x"));
    assert(!validRefName("refs/heads/../x"));
    assert(!validRefName("refs/heads/"));
    assert(!validRefName("HEAD/x"));
}
