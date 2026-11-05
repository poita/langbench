/// The in-memory virtual file system a session runs against.
module kiln.vfs;

import std.algorithm.sorting : sort;
import kiln.hash : fnv1a;
import kiln.paths : isGlobEligible, isGeneratedPath, stateFilePath;
import kiln.bytes : startsWithBytes;

/// One file: immutable content shared by handle, plus a lazily cached hash.
final class FileRec
{
    string data;
    ulong hash;
    bool hashValid;
    /// Modification stamp; only `touch` updates it and nothing reads it.
    ulong stamp;

    this(string data)
    {
        this.data = data;
    }
}

/// A flat map from workspace paths to file contents, with content hashes
/// cached per file and a sorted index of glob-eligible paths.
final class Vfs
{
    private FileRec[string] files;
    private string[] index;
    private bool indexDirty = true;
    private ulong clock;

    /// True when a file exists at `path`.
    bool exists(const(char)[] path) const
    {
        return (path in files) !is null;
    }

    /// Content of `path`, or null when absent. The buffer is shared, not copied.
    string read(const(char)[] path)
    {
        if (auto f = path in files)
            return f.data;
        return null;
    }

    /// Replace (or create) a file. Its hash is computed on first use.
    void write(string path, string data)
    {
        if (auto f = path in files)
        {
            f.data = data;
            f.hashValid = false;
        }
        else
        {
            files[path] = new FileRec(data);
            if (isGlobEligible(path))
                indexDirty = true;
        }
    }

    /// Replace (or create) a file whose hash is already known.
    void writeHashed(string path, string data, ulong hash)
    {
        write(path, data);
        auto f = files[path];
        f.hash = hash;
        f.hashValid = true;
    }

    /// Delete a file; returns whether it existed.
    bool remove(string path)
    {
        if (path !in files)
            return false;
        files.remove(path);
        if (isGlobEligible(path))
            indexDirty = true;
        return true;
    }

    /// Update the modification stamp of `path` (no other effect).
    void touch(const(char)[] path)
    {
        if (auto f = path in files)
            f.stamp = ++clock;
    }

    /// Content hash of an existing file, cached until the content changes.
    ulong hashOf(const(char)[] path)
    {
        auto f = path in files;
        assert(f !is null, "hashOf: no such file");
        if (!f.hashValid)
        {
            f.hash = fnv1a(f.data);
            f.hashValid = true;
        }
        return f.hash;
    }

    /// Every path, sorted ascending by byte order.
    string[] allPaths()
    {
        auto r = files.keys;
        r.sort();
        return r;
    }

    /// Number of files.
    @property size_t length() const
    {
        return files.length;
    }

    /// Remove every generated path and the state file; returns the removed
    /// paths sorted ascending.
    string[] clean()
    {
        string[] gone;
        foreach (p; files.byKey)
            if (isGeneratedPath(p) || p == stateFilePath)
                gone ~= p;
        gone.sort();
        foreach (p; gone)
            files.remove(p);
        return gone;
    }

    /// Glob-eligible paths whose bytes start with `prefix`, sorted ascending.
    /// The slice is valid until the next mutation of the file set.
    string[] eligibleWithPrefix(const(char)[] prefix)
    {
        if (indexDirty)
        {
            index.length = 0;
            foreach (p; files.byKey)
                if (isGlobEligible(p))
                    index ~= p;
            index.sort();
            indexDirty = false;
        }
        // lower bound of `prefix` in the sorted index
        size_t lo = 0, hi = index.length;
        while (lo < hi)
        {
            immutable mid = (lo + hi) / 2;
            if (index[mid] < prefix)
                lo = mid + 1;
            else
                hi = mid;
        }
        size_t end = lo;
        while (end < index.length && startsWithBytes(index[end], prefix))
            ++end;
        return index[lo .. end];
    }
}
