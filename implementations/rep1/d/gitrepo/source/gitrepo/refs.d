/// Ref lookup: `HEAD`, loose refs under `refs/`, and `packed-refs`.
module gitrepo.refs;

import std.exception : assumeUnique;
import std.file;

import gitrepo.oid;

/// Maximum number of `ref: ` indirections followed.
enum maxSymrefDepth = 5;

private struct Resolved
{
    bool ok;
    ObjectId id;
}

/// The refs of one repository. `packed-refs` is parsed once; lookups are memoised.
final class RefDb
{
    private string gitDir;
    private ObjectId[string] packed;
    private Resolved[string] memo;

    /// Opens the refs of the repository at `gitDir` (missing files are treated as absent).
    this(string gitDir)
    {
        this.gitDir = gitDir;
        loadPacked();
    }

    private void loadPacked()
    {
        immutable path = gitDir ~ "/packed-refs";
        if (!exists(path) || !isFile(path))
            return;
        string text;
        try
            text = assumeUnique(cast(char[]) std.file.read(path));
        catch (Exception)
            return;
        size_t p = 0;
        while (p < text.length)
        {
            size_t e = p;
            while (e < text.length && text[e] != '\n')
                ++e;
            immutable line = text[p .. e];
            p = e + 1;
            if (line.length == 0 || line[0] == '#' || line[0] == '^')
                continue;
            ObjectId id;
            if (line.length > 41 && line[40] == ' ' && ObjectId.tryParse(line[0 .. 40], id))
                packed[line[41 .. $]] = id;
        }
    }

    /// True if `name` is `HEAD` or starts with `refs/` and has no empty, `.` or `..` component.
    static bool isRefName(scope const(char)[] name) @safe pure nothrow @nogc
    {
        if (name != "HEAD" && !(name.length > 5 && name[0 .. 5] == "refs/"))
            return false;
        size_t start = 0;
        foreach (i; 0 .. name.length + 1)
        {
            if (i == name.length || name[i] == '/')
            {
                const comp = name[start .. i];
                if (comp.length == 0 || comp == "." || comp == "..")
                    return false;
                start = i + 1;
            }
            else if (name[i] == 0)
                return false;
        }
        return true;
    }

    /// Resolves the ref called exactly `name` to an object id (the object need not exist).
    bool resolve(string name, out ObjectId id)
    {
        return resolveDepth(name, 0, id);
    }

    private bool resolveDepth(string name, int depth, out ObjectId id)
    {
        if (!isRefName(name))
            return false;
        // Memoising only plain lookups keeps the symref depth accounting simple.
        if (depth == 0)
        {
            if (auto r = name in memo)
            {
                id = r.id;
                return r.ok;
            }
        }
        immutable ok = resolveUncached(name, depth, id);
        if (depth == 0)
            memo[name] = Resolved(ok, id);
        return ok;
    }

    private bool resolveUncached(string name, int depth, out ObjectId id)
    {
        immutable path = gitDir ~ "/" ~ name;
        if (exists(path) && isFile(path))
        {
            string text;
            try
                text = assumeUnique(cast(char[]) std.file.read(path));
            catch (Exception)
                return false;
            size_t end = text.length;
            while (end > 0 && isWs(text[end - 1]))
                --end;
            text = text[0 .. end];
            if (text.length >= 5 && text[0 .. 5] == "ref: ")
            {
                if (depth >= maxSymrefDepth)
                    return false;
                return resolveDepth(text[5 .. $], depth + 1, id);
            }
            return ObjectId.tryParse(text, id);
        }
        if (auto p = name in packed)
        {
            id = *p;
            return true;
        }
        return false;
    }

    private static bool isWs(char c) @safe pure nothrow @nogc
    {
        return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f';
    }
}
