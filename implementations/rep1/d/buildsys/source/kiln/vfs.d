/// The virtual file system: path -> immutable content with cached hashes.
module kiln.vfs;

import kiln.hash : fnv1a;
import kiln.paths : isGlobEligible;

/// An in-memory flat file system.
///
/// Content buffers are immutable and shared by reference, so reading a file
/// never copies it. Each file caches its FNV-1a hash, computed lazily.
final class Vfs
{
    private static struct Rec
    {
        string content;
        ulong hash;
        bool hashValid;
        long stamp;
    }

    private Rec[string] files;
    private string[] index; // sorted glob-eligible paths
    private bool indexDirty = true;
    private long stampCounter;

    /// True if a file exists at `path`.
    bool exists(const(char)[] path) const @safe
    {
        return (path in files) !is null;
    }

    /// The content of `path`, which must exist.
    string content(const(char)[] path) const @safe
    {
        return files[path].content;
    }

    /// The content hash of `path`, which must exist. Computed at most once per content.
    ulong hash(const(char)[] path) @safe
    {
        auto r = path in files;
        assert(r !is null);
        if (!r.hashValid)
        {
            r.hash = fnv1a(r.content);
            r.hashValid = true;
        }
        return r.hash;
    }

    /// Creates or replaces a file; its hash is computed on first use.
    void put(string path, string content) @safe
    {
        if (auto r = path in files)
        {
            r.content = content;
            r.hashValid = false;
            r.stamp = ++stampCounter;
        }
        else
        {
            files[path] = Rec(content, 0, false, ++stampCounter);
            if (isGlobEligible(path))
                indexDirty = true;
        }
    }

    /// Creates or replaces a file whose hash is already known.
    void putHashed(string path, string content, ulong h) @safe
    {
        put(path, content);
        auto r = path in files;
        r.hash = h;
        r.hashValid = true;
    }

    /// Removes a file; returns whether it existed.
    bool remove(string path) @safe
    {
        if (path !in files)
            return false;
        files.remove(path);
        if (isGlobEligible(path))
            indexDirty = true;
        return true;
    }

    /// Updates the modification stamp of a file (never used for change detection).
    void touch(const(char)[] path) @safe
    {
        if (auto r = path in files)
            r.stamp = ++stampCounter;
    }

    /// Number of files.
    size_t length() const @safe
    {
        return files.length;
    }

    /// Every path, sorted ascending by byte order.
    string[] paths() @safe
    {
        import std.algorithm.sorting : sort;

        auto r = files.keys;
        r.sort();
        return r;
    }

    /// Sorted list of glob-eligible paths (rebuilt lazily when the set changed).
    const(string)[] globIndex() @safe
    {
        if (indexDirty)
        {
            import std.algorithm.sorting : sort;

            string[] r;
            r.reserve(files.length);
            foreach (k, ref v; files)
                if (isGlobEligible(k))
                    r ~= k;
            r.sort();
            index = r;
            indexDirty = false;
        }
        return index;
    }

    /// The contiguous slice of the glob index whose paths start with `prefix`.
    const(string)[] globRange(const(char)[] prefix) @safe
    {
        auto idx = globIndex();
        if (prefix.length == 0)
            return idx;
        // lower bound
        size_t lo = 0, hi = idx.length;
        while (lo < hi)
        {
            const mid = lo + (hi - lo) / 2;
            if (idx[mid] < prefix)
                lo = mid + 1;
            else
                hi = mid;
        }
        size_t end = lo;
        while (end < idx.length && idx[end].length >= prefix.length
                && idx[end][0 .. prefix.length] == prefix)
            ++end;
        return idx[lo .. end];
    }
}
