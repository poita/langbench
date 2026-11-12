/**
 * The virtual file system a Kiln session runs against.
 *
 * A $(LREF Workspace) maps workspace paths to file contents. Each file caches
 * its FNV-1a hash (computed at most once per distinct content), and a sorted
 * index of the paths eligible for `glob` is kept up to date incrementally so a
 * glob costs a binary search plus the paths that share its wildcard-free prefix.
 */
module kiln.workspace;

import kiln.bytes : cmpBytes, startsWith;
import kiln.glob : GlobPattern;
import kiln.hash : fnv1a;

/// True if `s` is a valid workspace path.
bool isWorkspacePath(const(char)[] s) @safe pure nothrow @nogc
{
    if (s.length == 0 || s.length > 1024)
        return false;
    size_t start = 0;
    foreach (i; 0 .. s.length + 1)
    {
        if (i == s.length || s[i] == '/')
        {
            immutable len = i - start;
            if (len == 0 || len > 255)
                return false;
            auto comp = s[start .. i];
            if (comp == "." || comp == "..")
                return false;
            start = i + 1;
        }
        else
        {
            immutable c = s[i];
            immutable ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '+' || c == '-';
            if (!ok)
                return false;
        }
    }
    return true;
}

/// True if the first component of `path` is exactly `out`.
bool isGeneratedPath(const(char)[] path) @safe pure nothrow @nogc
{
    return path == "out" || startsWith(path, "out/");
}

/// The name of the persisted build-state file.
enum stateFileName = ".kiln-state";

/// One file of the workspace.
final class FileEntry
{
    /// The file's bytes.
    string content;
    /// Modification stamp; only `touch` sets it and nothing ever reads it.
    ulong stamp;
    private ulong cachedHash;
    private bool hashed;

    this(string content) @safe pure nothrow @nogc
    {
        this.content = content;
    }

    /// The FNV-1a hash of the content, computed on first use.
    ulong hash() @safe pure nothrow @nogc
    {
        if (!hashed)
        {
            cachedHash = fnv1a(content);
            hashed = true;
        }
        return cachedHash;
    }

    private void replace(string newContent) @safe pure nothrow @nogc
    {
        if (newContent == content)
            return; // identical bytes: keep the cached hash
        content = newContent;
        hashed = false;
    }
}

/// The in-memory workspace.
final class Workspace
{
    private FileEntry[string] files;
    private string[] globIndex; // sorted paths eligible for glob
    private ulong clock;

    /// Number of files.
    size_t length() const @safe pure nothrow @nogc
    {
        return files.length;
    }

    /// Whether a file exists at `path`.
    bool exists(const(char)[] path) const @safe pure nothrow
    {
        return (path in files) !is null;
    }

    /// The entry at `path`, or `null`.
    FileEntry find(const(char)[] path) @safe pure nothrow
    {
        auto p = path in files;
        return p ? *p : null;
    }

    /// The content at `path`; `path` must exist.
    string read(const(char)[] path) @safe pure
    {
        auto p = path in files;
        assert(p !is null, "no such file: " ~ path);
        return p.content;
    }

    /**
     * The content hash at `path`. Returns false when there is no such file.
     */
    bool hashOf(const(char)[] path, out ulong h) @safe pure nothrow
    {
        auto p = path in files;
        if (p is null)
            return false;
        h = p.hash();
        return true;
    }

    /// Creates or replaces the file at `path`.
    void write(string path, string content) @safe pure nothrow
    {
        if (auto p = path in files)
        {
            p.replace(content);
            return;
        }
        files[path] = new FileEntry(content);
        if (isGlobEligible(path))
            indexInsert(path);
    }

    /// Removes the file at `path` if present; returns whether it existed.
    bool remove(string path) @safe pure nothrow
    {
        if (path !in files)
            return false;
        files.remove(path);
        if (isGlobEligible(path))
            indexRemove(path);
        return true;
    }

    /// Updates the modification stamp of `path` (no effect on anything else).
    void touch(const(char)[] path) @safe pure nothrow
    {
        if (auto p = path in files)
            p.stamp = ++clock;
    }

    /// All paths, sorted ascending by byte order.
    string[] paths() @safe pure nothrow
    {
        auto r = files.keys;
        sortPaths(r);
        return r;
    }

    /// Removes every generated path and the state file; returns the removed paths, sorted.
    string[] clean() @safe pure nothrow
    {
        string[] gone;
        foreach (p; files.byKey)
            if (isGeneratedPath(p) || p == stateFileName)
                gone ~= p;
        sortPaths(gone);
        foreach (p; gone)
            remove(p);
        return gone;
    }

    /**
     * The sorted workspace paths that `pattern` matches, excluding generated
     * paths and the state file.
     */
    string[] glob(const ref GlobPattern pattern) @safe pure nothrow
    {
        string[] result;
        immutable pre = pattern.prefix;
        size_t i = lowerBound(pre);
        for (; i < globIndex.length; i++)
        {
            auto p = globIndex[i];
            if (!startsWith(p, pre))
                break;
            if (pattern.matches(p))
                result ~= p;
        }
        return result;
    }

    private static bool isGlobEligible(const(char)[] path) @safe pure nothrow @nogc
    {
        return !isGeneratedPath(path) && path != stateFileName;
    }

    /// First index whose path is >= `key`.
    private size_t lowerBound(const(char)[] key) const @safe pure nothrow @nogc
    {
        size_t lo = 0, hi = globIndex.length;
        while (lo < hi)
        {
            immutable mid = lo + (hi - lo) / 2;
            if (cmpBytes(globIndex[mid], key) < 0)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo;
    }

    private void indexInsert(string path) @safe pure nothrow
    {
        immutable i = lowerBound(path);
        globIndex.length += 1;
        foreach_reverse (j; i .. globIndex.length - 1)
            globIndex[j + 1] = globIndex[j];
        globIndex[i] = path;
    }

    private void indexRemove(const(char)[] path) @safe pure nothrow
    {
        immutable i = lowerBound(path);
        if (i < globIndex.length && globIndex[i] == path)
        {
            foreach (j; i + 1 .. globIndex.length)
                globIndex[j - 1] = globIndex[j];
            globIndex.length -= 1;
        }
    }
}

/// Sorts `paths` ascending by byte order.
void sortPaths(string[] paths) @safe pure nothrow
{
    import std.algorithm.sorting : sort;

    paths.sort!((a, b) => cmpBytes(a, b) < 0);
}

/**
 * Loads a workspace from a real directory: every regular file below `dir`,
 * except the top-level `session.txt`, becomes an entry.
 */
Workspace loadWorkspace(string dir, string skipTopLevel = "session.txt")
{
    import std.file : dirEntries, read, SpanMode;
    import std.path : buildNormalizedPath, absolutePath;
    import std.array : replace;

    auto ws = new Workspace;
    immutable root = absolutePath(buildNormalizedPath(dir));
    foreach (e; dirEntries(root, SpanMode.depth, false))
    {
        if (!e.isFile)
            continue;
        string rel = e.name[root.length .. $];
        while (rel.length && rel[0] == '/')
            rel = rel[1 .. $];
        version (Windows)
            rel = rel.replace("\\", "/");
        if (rel == skipTopLevel)
            continue;
        auto bytes = cast(string) read(e.name);
        ws.write(rel, bytes);
    }
    return ws;
}

/// Writes every file of `ws` below `dir`/`subdir` (creating directories as needed).
void writeWorkspace(Workspace ws, string dir, string subdir = "workspace")
{
    import std.file : mkdirRecurse, write;
    import std.path : buildPath, dirName;

    auto base = buildPath(dir, subdir);
    mkdirRecurse(base);
    foreach (p; ws.paths())
    {
        auto target = buildPath(base, p);
        mkdirRecurse(dirName(target));
        write(target, ws.read(p));
    }
}

@safe pure nothrow unittest
{
    assert(isWorkspacePath("a/b.c-d+e_f"));
    assert(!isWorkspacePath("") && !isWorkspacePath("/a") && !isWorkspacePath("a/")
            && !isWorkspacePath("a//b") && !isWorkspacePath("a/../b") && !isWorkspacePath("./a")
            && !isWorkspacePath("a b") && !isWorkspacePath("a@b") && !isWorkspacePath("a*"));
    assert(isGeneratedPath("out/x") && isGeneratedPath("out") && !isGeneratedPath("outx/y"));
}

@safe pure unittest
{
    import kiln.glob : compileGlob;

    auto ws = new Workspace;
    ws.write("src/b.txt", "b");
    ws.write("src/a.txt", "a");
    ws.write("src/sub/c.txt", "c");
    ws.write("out/gen.txt", "g");
    ws.write(".kiln-state", "s");
    ws.write("zzz.txt", "z");
    GlobPattern p;
    assert(compileGlob("**/*.txt", p));
    assert(ws.glob(p) == ["src/a.txt", "src/b.txt", "src/sub/c.txt", "zzz.txt"]);
    assert(compileGlob("src/*.txt", p));
    assert(ws.glob(p) == ["src/a.txt", "src/b.txt"]);
    ws.remove("src/a.txt");
    assert(ws.glob(p) == ["src/b.txt"]);
    assert(ws.clean() == [".kiln-state", "out/gen.txt"]);
    ulong h;
    assert(ws.hashOf("zzz.txt", h) && h == fnv1a("z"));
    assert(!ws.hashOf("nope", h));
}
