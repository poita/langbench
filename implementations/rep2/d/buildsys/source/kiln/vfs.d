/**
 * The in-memory virtual file system that holds a workspace.
 *
 * Every file has immutable content that is shared by handle (a D slice) and a
 * cached FNV-1a hash that is computed at most once per distinct content.
 * A sorted index of the glob-eligible paths supports prefix-narrowed lookups.
 */
module kiln.vfs;

import kiln.hash;
import kiln.paths;

import std.algorithm : sort;
static import std.file;
import std.path : dirName, buildPath;

/// A file in the workspace.
final class FileRecord
{
    /// Immutable content, shared by reference.
    string content;
    /// Cached hash of `content`, valid only when `hashValid`.
    ulong hash;
    /// Whether `hash` is current.
    bool hashValid;
    /// Modification stamp; only `touch` updates it and nothing reads it.
    ulong stamp;
}

/// A flat map from workspace paths to file contents.
final class Vfs
{
    private FileRecord[string] files;
    private string[] globIndex;
    private bool globDirty = true;
    private ulong clock;

    /// Number of files.
    size_t length() const
    {
        return files.length;
    }

    /// True iff a file exists at `path`.
    bool exists(string path) const
    {
        return (path in files) !is null;
    }

    /// Content of the file at `path`; the file must exist.
    string read(string path)
    {
        return files[path].content;
    }

    /// Creates or replaces a file; its hash is computed lazily.
    void write(string path, string content)
    {
        if (auto r = path in files)
        {
            r.content = content;
            r.hashValid = false;
        }
        else
        {
            auto r2 = new FileRecord;
            r2.content = content;
            files[path] = r2;
            if (isGlobEligible(path))
                globDirty = true;
        }
    }

    /// Creates or replaces a file whose hash is already known.
    void writeWithHash(string path, string content, ulong hash)
    {
        write(path, content);
        auto r = files[path];
        r.hash = hash;
        r.hashValid = true;
    }

    /// Removes a file; returns whether it existed.
    bool remove(string path)
    {
        if (path !in files)
            return false;
        files.remove(path);
        if (isGlobEligible(path))
            globDirty = true;
        return true;
    }

    /// Updates the modification stamp. Never affects change detection.
    void touch(string path)
    {
        if (auto r = path in files)
            r.stamp = ++clock;
    }

    /// FNV-1a hash of the file's content, cached on the file record.
    ulong hashOf(string path)
    {
        auto r = files[path];
        if (!r.hashValid)
        {
            r.hash = fnv1a(r.content);
            r.hashValid = true;
        }
        return r.hash;
    }

    /// All paths in ascending byte order.
    string[] paths()
    {
        auto p = files.keys;
        p.sort();
        return p;
    }

    /// Removes every generated path and the state file; returns the removed
    /// paths in ascending order.
    string[] clean()
    {
        string[] gone;
        foreach (p; files.byKey)
            if (!isGlobEligible(p))
                gone ~= p;
        gone.sort();
        foreach (p; gone)
            remove(p);
        return gone;
    }

    /**
     * Sorted glob-eligible paths that start with `prefix` (a byte prefix, not
     * necessarily on a component boundary). Found by binary search.
     */
    const(string)[] globRange(string prefix)
    {
        if (globDirty)
        {
            globIndex.length = 0;
            foreach (p; files.byKey)
                if (isGlobEligible(p))
                    globIndex ~= p;
            globIndex.sort();
            globDirty = false;
        }
        size_t lo = 0, hi = globIndex.length;
        while (lo < hi)
        {
            immutable mid = (lo + hi) / 2;
            if (globIndex[mid] < prefix)
                lo = mid + 1;
            else
                hi = mid;
        }
        size_t end = lo;
        while (end < globIndex.length && globIndex[end].length >= prefix.length
                && globIndex[end][0 .. prefix.length] == prefix)
            end++;
        return globIndex[lo .. end];
    }

    /**
     * Loads every regular file below `dir` (recursively). The top-level file
     * named in `skip`, if any, is not loaded.
     */
    void loadFrom(string dir, string skip = null)
    {
        immutable prefix = (dir.length && dir[$ - 1] == '/') ? dir : dir ~ "/";
        foreach (e; std.file.dirEntries(dir, std.file.SpanMode.depth))
        {
            if (!e.isFile)
                continue;
            string rel = e.name[prefix.length .. $];
            if (skip.length && rel == skip)
                continue;
            write(rel, cast(string) std.file.read(e.name));
        }
    }

    /// Writes every file below `dir`, creating each directory once.
    void saveTo(string dir)
    {
        bool[string] made;
        std.file.mkdirRecurse(dir);
        made[dir] = true;
        foreach (p, rec; files)
        {
            immutable full = buildPath(dir, p);
            immutable parent = dirName(full);
            if (parent !in made)
            {
                std.file.mkdirRecurse(parent);
                made[parent] = true;
            }
            std.file.write(full, rec.content);
        }
    }
}
