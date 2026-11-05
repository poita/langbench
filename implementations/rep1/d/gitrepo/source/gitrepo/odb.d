/// The object store: loose objects and packfiles behind one lookup, with caches.
module gitrepo.odb;

import std.algorithm.sorting : sort;
import std.exception : assumeUnique;
import std.file;
import std.path : baseName, stripExtension;

import gitrepo.delta;
import gitrepo.errors;
import gitrepo.inflate;
import gitrepo.oid;
import gitrepo.pack;

/// A fully reconstructed object: its type and payload (no header).
struct RawObject
{
    ///
    ObjectType type;
    /// The payload. Shared between all users; never modified.
    immutable(ubyte)[] data;
}

private struct Cached
{
    RawObject obj;
    bool bad;
}

private enum maxDeltaDepth = 1000;

/// Read-only access to `<gitDir>/objects`. Everything read is memoised for the
/// lifetime of the store (the repository is assumed not to change underneath it).
final class ObjectStore
{
    private string objectsDir;
    private bool[ObjectId] looseSet;
    private Pack[] packList;
    private Cached[ulong] packCache;
    private Cached[ObjectId] looseCache;
    private Inflater inflater;
    private ObjectId[] sortedIds;
    private bool sortedBuilt;

    /// Number of loose object files with well-formed names.
    size_t looseCount;
    /// Number of `.idx` files that have a matching `.pack`.
    size_t packCount;
    /// Sum of the object counts of those indexes.
    size_t inPackCount;

    /// Opens the object database of the repository at `gitDir`. Missing pieces are treated as empty.
    this(string gitDir)
    {
        objectsDir = gitDir ~ "/objects";
        inflater = new Inflater;
        scanLoose();
        scanPacks();
    }

    /// The usable packs, in the fixed order used for lookups.
    const(Pack)[] packs() const @safe pure nothrow @nogc
    {
        return packList;
    }

    private static bool dirExists(string path)
    {
        return exists(path) && isDir(path);
    }

    private static bool isLowerHex(string s) @safe pure nothrow @nogc
    {
        foreach (c; s)
            if (hexValue(c, true) < 0)
                return false;
        return true;
    }

    private void scanLoose()
    {
        if (!dirExists(objectsDir))
            return;
        foreach (de; dirEntries(objectsDir, SpanMode.shallow))
        {
            immutable dir = baseName(de.name);
            if (dir.length != 2 || !isLowerHex(dir) || !de.isDir)
                continue;
            foreach (f; dirEntries(de.name, SpanMode.shallow))
            {
                immutable fn = baseName(f.name);
                if (fn.length != 38 || !isLowerHex(fn) || !f.isFile)
                    continue;
                ObjectId id;
                if (ObjectId.tryParse(dir ~ fn, id))
                {
                    looseSet[id] = true;
                    ++looseCount;
                }
            }
        }
    }

    private void scanPacks()
    {
        immutable packDir = objectsDir ~ "/pack";
        if (!dirExists(packDir))
            return;
        string[] names;
        foreach (de; dirEntries(packDir, SpanMode.shallow))
        {
            immutable fn = baseName(de.name);
            if (fn.length > 4 && fn[$ - 4 .. $] == ".idx" && de.isFile)
            {
                immutable stem = fn[0 .. $ - 4];
                if (exists(packDir ~ "/" ~ stem ~ ".pack") && isFile(packDir ~ "/" ~ stem ~ ".pack"))
                    names ~= stem;
            }
        }
        names.sort();
        foreach (stem; names)
        {
            ++packCount;
            try
            {
                auto idx = readBytes(packDir ~ "/" ~ stem ~ ".idx");
                if (idx.length >= 1032)
                    inPackCount += be32(idx, 8 + 255 * 4);
                auto data = readBytes(packDir ~ "/" ~ stem ~ ".pack");
                packList ~= new Pack(stem, idx, data);
            }
            catch (Exception)
            {
                // unreadable or malformed pack: counted above, but never used for lookups
            }
        }
    }

    private static immutable(ubyte)[] readBytes(string path)
    {
        return assumeUnique(cast(ubyte[]) std.file.read(path));
    }

    /// True if the object is a loose file or has an entry in a pack index. Nothing is read.
    bool has(const ObjectId id) const @safe
    {
        if (id in looseSet)
            return true;
        foreach (p; packList)
            if (p.find(id) >= 0)
                return true;
        return false;
    }

    /// Reads (and memoises) the object with the given id. Throws `GitError` if it is
    /// missing or damaged. A loose copy wins over a packed one.
    RawObject read(const ObjectId id) 
    {
        return readDepth(id, 0);
    }

    private RawObject readDepth(const ObjectId id, int depth)
    {
        if (depth > maxDeltaDepth)
            throw new GitError("delta chain too deep");
        if (id in looseSet)
        {
            if (auto c = id in looseCache)
            {
                if (c.bad)
                    throw new GitError("damaged loose object");
                return c.obj;
            }
            try
            {
                auto o = readLoose(id);
                looseCache[id] = Cached(o, false);
                return o;
            }
            catch (GitError e)
            {
                looseCache[id] = Cached(RawObject.init, true);
                throw e;
            }
        }
        foreach (pi, p; packList)
        {
            immutable off = p.find(id);
            if (off >= 0)
                return readPacked(pi, off, depth);
        }
        throw new GitError("object not found");
    }

    private RawObject readLoose(const ObjectId id)
    {
        immutable hex = id.toString();
        immutable path = objectsDir ~ "/" ~ hex[0 .. 2] ~ "/" ~ hex[2 .. $];
        immutable raw = readBytes(path);
        immutable plain = assumeUnique(inflater.decompress(raw, raw.length * 3));
        size_t p = 0;
        ObjectType type;
        if (startsWith(plain, "commit "))
        {
            type = ObjectType.commit;
            p = 7;
        }
        else if (startsWith(plain, "tree "))
        {
            type = ObjectType.tree;
            p = 5;
        }
        else if (startsWith(plain, "blob "))
        {
            type = ObjectType.blob;
            p = 5;
        }
        else if (startsWith(plain, "tag "))
        {
            type = ObjectType.tag;
            p = 4;
        }
        else
            throw new GitError("bad loose object type");
        ulong size = 0;
        immutable digitsStart = p;
        while (p < plain.length && plain[p] >= '0' && plain[p] <= '9')
        {
            if (size > (ulong.max - 9) / 10)
                throw new GitError("bad loose object size");
            size = size * 10 + (plain[p] - '0');
            ++p;
        }
        if (p == digitsStart || p >= plain.length || plain[p] != 0)
            throw new GitError("bad loose object header");
        ++p;
        if (plain.length - p != size)
            throw new GitError("loose object size mismatch");
        return RawObject(type, plain[p .. $]);
    }

    private static bool startsWith(scope const(ubyte)[] a, string prefix) @safe pure nothrow @nogc
    {
        return a.length >= prefix.length && a[0 .. prefix.length] == cast(const(ubyte)[]) prefix;
    }

    private RawObject readPacked(size_t packIndex, long offset, int depth)
    {
        immutable key = (cast(ulong) packIndex << 48) | cast(ulong) offset;
        if (auto c = key in packCache)
        {
            if (c.bad)
                throw new GitError("damaged packed object");
            return c.obj;
        }
        try
        {
            auto o = readPackedUncached(packIndex, offset, depth);
            packCache[key] = Cached(o, false);
            return o;
        }
        catch (GitError e)
        {
            packCache[key] = Cached(RawObject.init, true);
            throw e;
        }
    }

    private RawObject readPackedUncached(size_t packIndex, long offset, int depth)
    {
        if (depth > maxDeltaDepth)
            throw new GitError("delta chain too deep");
        auto pack = packList[packIndex];
        immutable data = pack.data;
        immutable end = data.length - 20;
        if (offset < 12 || offset >= end)
            throw new GitError("object offset outside pack");
        size_t p = cast(size_t) offset;
        ubyte b = data[p++];
        immutable kind = (b >> 4) & 7;
        ulong size = b & 15;
        uint shift = 4;
        while (b & 0x80)
        {
            if (p >= end || shift > 56)
                throw new GitError("bad pack object header");
            b = data[p++];
            size |= cast(ulong)(b & 0x7f) << shift;
            shift += 7;
        }
        switch (kind)
        {
        case 1: .. case 4:
            return RawObject(cast(ObjectType) kind, inflateAt(data, p, size));
        case 6:
            if (p >= end)
                throw new GitError("bad pack object header");
            b = data[p++];
            ulong v = b & 0x7f;
            while (b & 0x80)
            {
                if (p >= end || v > (ulong.max >> 8))
                    throw new GitError("bad pack object header");
                b = data[p++];
                v = ((v + 1) << 7) | (b & 0x7f);
            }
            if (v == 0 || v > cast(ulong) offset)
                throw new GitError("bad delta base offset");
            auto delta = inflateAt(data, p, size);
            auto base = readPacked(packIndex, offset - cast(long) v, depth + 1);
            return RawObject(base.type, assumeUnique(applyDelta(base.data, delta)));
        case 7:
            if (end - p < 20)
                throw new GitError("bad pack object header");
            ObjectId baseId;
            baseId.bytes[] = data[p .. p + 20];
            p += 20;
            auto delta = inflateAt(data, p, size);
            auto base = readDepth(baseId, depth + 1);
            return RawObject(base.type, assumeUnique(applyDelta(base.data, delta)));
        default:
            throw new GitError("invalid pack object type");
        }
    }

    private immutable(ubyte)[] inflateAt(immutable(ubyte)[] data, size_t p, ulong sizeHint)
    {
        return assumeUnique(inflater.decompress(data[p .. data.length - 20], cast(size_t)(sizeHint < maxInitialCapacity ? sizeHint : maxInitialCapacity)));
    }

    /// Ids of all objects (loose and packed), ascending and without duplicates.
    const(ObjectId)[] allIds()
    {
        if (!sortedBuilt)
        {
            ObjectId[] all;
            all.reserve(looseSet.length);
            foreach (id; looseSet.byKey)
                all ~= id;
            foreach (p; packList)
                foreach (i; 0 .. p.count)
                    all ~= p.idAt(i);
            all.sort();
            size_t n = 0;
            foreach (i, id; all)
            {
                if (i == 0 || id != all[n - 1])
                    all[n++] = id;
            }
            sortedIds = all[0 .. n];
            sortedBuilt = true;
        }
        return sortedIds;
    }
}
