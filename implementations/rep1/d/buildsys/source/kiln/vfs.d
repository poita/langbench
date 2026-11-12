/**
 * The virtual file system: a flat map from workspace paths to contents, with
 * lazily cached content hashes and a sorted index for `glob`.
 */
module kiln.vfs;

import kiln.glob : GlobPattern;
import kiln.hash : fnv1a;
import kiln.text : cmpBytes, isGeneratedPath, startsWithBytes;

/// The path of the persisted build state.
enum stateFilePath = ".kiln-state";

/// One file: its content, a cached hash of that content and a modification stamp.
final class FileEntry
{
    /// The file's bytes.
    string content;
    /// Modification stamp (updated by `touch`; never used for change detection).
    ulong stamp;
    private ulong cachedHash;
    private bool hashed;

    ///
    this(string content, ulong stamp = 0) @safe pure nothrow @nogc
    {
        this.content = content;
        this.stamp = stamp;
    }

    /// FNV-1a hash of the content, computed once per distinct content.
    ulong hash() @safe pure nothrow @nogc
    {
        if (!hashed)
        {
            cachedHash = fnv1a(content);
            hashed = true;
        }
        return cachedHash;
    }
}

/// The virtual file system of a session.
final class Vfs
{
    private FileEntry[string] files;
    private string[] globIndex;
    private bool globIndexDirty = true;
    private ulong clock;

    /// True if a file exists at `path`.
    bool exists(const(char)[] path) const
    {
        return (path in files) !is null;
    }

    /// The entry at `path`, or null.
    FileEntry get(const(char)[] path)
    {
        auto p = path in files;
        return p ? *p : null;
    }

    /// Content of `path`; null if absent.
    string read(const(char)[] path)
    {
        auto f = get(path);
        return f is null ? null : f.content;
    }

    /// Creates or replaces the file at `path`.
    void write(string path, string content)
    {
        auto p = path in files;
        if (p is null)
        {
            if (isGlobbable(path))
                globIndexDirty = true;
            files[path] = new FileEntry(content, ++clock);
        }
        else
        {
            *p = new FileEntry(content, ++clock);
        }
    }

    /// Removes the file at `path`; returns whether it existed.
    bool remove(string path)
    {
        if ((path in files) is null)
            return false;
        if (isGlobbable(path))
            globIndexDirty = true;
        files.remove(path);
        return true;
    }

    /// Updates the modification stamp of `path` (and nothing else).
    void touch(const(char)[] path)
    {
        if (auto f = get(path))
            f.stamp = ++clock;
    }

    /// Hash of the file at `path`; false if the file does not exist.
    bool hashOf(const(char)[] path, out ulong h)
    {
        auto f = get(path);
        if (f is null)
            return false;
        h = f.hash();
        return true;
    }

    /// All paths, sorted ascending by byte order.
    string[] paths()
    {
        import std.algorithm.sorting : sort;

        auto r = files.keys;
        r.sort!((a, b) => cmpBytes(a, b) < 0);
        return r;
    }

    /// Number of files.
    size_t length() const { return files.length; }

    /// Whether `glob` may see `path`: not under `out/` and not the state file.
    static bool isGlobbable(const(char)[] path) @safe pure nothrow @nogc
    {
        return !isGeneratedPath(path) && path != stateFilePath;
    }

    /// The sorted workspace paths matching `pattern` (excluding generated files and the state file).
    string[] glob(ref const GlobPattern pattern)
    {
        import std.algorithm.sorting : sort;

        if (globIndexDirty)
        {
            globIndex.length = 0;
            foreach (k; files.byKey)
                if (isGlobbable(k))
                    globIndex ~= k;
            globIndex.sort!((a, b) => cmpBytes(a, b) < 0);
            globIndexDirty = false;
        }
        const prefix = pattern.literalPrefix;
        // Lower bound of the prefix in the sorted index.
        size_t lo = 0, hi = globIndex.length;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            if (cmpBytes(globIndex[mid], prefix) < 0)
                lo = mid + 1;
            else
                hi = mid;
        }
        string[] result;
        for (size_t i = lo; i < globIndex.length && startsWithBytes(globIndex[i], prefix); ++i)
            if (pattern.matches(globIndex[i]))
                result ~= globIndex[i];
        return result;
    }
}

unittest
{
    auto fs = new Vfs;
    fs.write("src/b.txt", "b\n");
    fs.write("src/a.txt", "a\n");
    fs.write("src/sub/c.txt", "c\n");
    fs.write("out/x.txt", "x\n");
    fs.write(".kiln-state", "kiln-state 1\n");
    GlobPattern g;
    assert(GlobPattern.compile("**/*.txt", g));
    assert(fs.glob(g) == ["src/a.txt", "src/b.txt", "src/sub/c.txt"]);
    assert(GlobPattern.compile("src/*.txt", g));
    assert(fs.glob(g) == ["src/a.txt", "src/b.txt"]);
    fs.write("src/0.txt", "0\n");
    fs.remove("src/b.txt");
    assert(fs.glob(g) == ["src/0.txt", "src/a.txt"]);
    assert(GlobPattern.compile("**", g));
    assert(fs.glob(g).length == 3);
}

unittest
{
    auto fs = new Vfs;
    fs.write("a", "hello\n");
    ulong h;
    assert(fs.hashOf("a", h) && h == fnv1a("hello\n"));
    assert(!fs.hashOf("b", h));
    const before = fs.get("a").stamp;
    fs.touch("a");
    assert(fs.get("a").stamp > before && fs.read("a") == "hello\n");
    assert(fs.paths() == ["a"]);
}
